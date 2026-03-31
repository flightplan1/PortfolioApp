import Foundation

struct CSVParser {

    // MARK: - Entry Point

    static func parse(url: URL) throws -> (mapping: CSVColumnMapping, result: ImportParseResult) {
        let raw = try String(contentsOf: url, encoding: .utf8)
        let lines = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        guard !lines.isEmpty else { throw ImportError.emptyFile }

        let headers = parseCSVRow(lines[0])
        guard !headers.isEmpty else { throw ImportError.noMappedColumns }

        let mapping = buildColumnMapping(headers: headers)

        var transactions: [ImportedTransaction] = []
        var issues: [ImportIssue] = []

        for (i, line) in lines.dropFirst().enumerated() {
            let rowIndex = i + 2  // 1-based, row 1 = header
            let cells = parseCSVRow(line)
            guard cells.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { continue }

            switch parseRow(cells: cells, mapping: mapping, rowIndex: rowIndex) {
            case .success(let tx):
                let rowIssues = validateRow(tx)
                issues.append(contentsOf: rowIssues)
                if !rowIssues.contains(where: { $0.isError }) {
                    transactions.append(tx)
                }
            case .failure(let issue):
                issues.append(issue)
            }
        }

        issues.append(contentsOf: validateCrossRows(transactions))

        return (mapping, ImportParseResult(transactions: transactions, issues: issues))
    }

    // MARK: - Column Mapping

    static func buildColumnMapping(headers: [String]) -> CSVColumnMapping {
        var mapping: [Int: ImportField] = [:]
        for (i, header) in headers.enumerated() {
            if let field = ImportField.detect(from: header) {
                mapping[i] = field
            }
        }
        return CSVColumnMapping(mapping: mapping, headers: headers)
    }

    // MARK: - Row Parsing

    private static func parseRow(cells: [String], mapping: CSVColumnMapping, rowIndex: Int) -> Result<ImportedTransaction, ImportIssue> {
        func cell(_ field: ImportField) -> String? {
            guard let col = mapping.mapping.first(where: { $0.value == field })?.key,
                  col < cells.count else { return nil }
            let v = cells[col].trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? nil : v
        }

        // Symbol (required)
        guard let symbolRaw = cell(.symbol) else {
            return .failure(ImportIssue(severity: .error, rowIndex: rowIndex, message: "Symbol is required"))
        }
        let symbol = symbolRaw.uppercased()

        // TradeDate (required)
        guard let dateStr = cell(.tradeDate) else {
            return .failure(ImportIssue(severity: .error, rowIndex: rowIndex, message: "TradeDate is required"))
        }
        guard let tradeDate = parseDate(dateStr) else {
            return .failure(ImportIssue(severity: .error, rowIndex: rowIndex,
                message: "Cannot parse date '\(dateStr)' — use YYYY-MM-DD"))
        }

        // Action (required)
        guard let actionStr = cell(.action) else {
            return .failure(ImportIssue(severity: .error, rowIndex: rowIndex, message: "Action is required"))
        }
        guard let action = ImportAction(rawInput: actionStr) else {
            return .failure(ImportIssue(severity: .error, rowIndex: rowIndex,
                message: "Unknown action '\(actionStr)' — use BUY, SELL, DIVIDEND, DRIP, or SPLIT"))
        }

        // Quantity
        let qtyStr = cell(.quantity) ?? ""
        let quantity: Decimal
        if action == .split {
            quantity = 0
        } else if let q = Decimal(string: qtyStr), q > 0 {
            quantity = q
        } else if action == .dividend || action == .drip {
            quantity = Decimal(string: qtyStr) ?? 0  // dividend qty can be 0
        } else {
            return .failure(ImportIssue(severity: .error, rowIndex: rowIndex,
                message: "Quantity must be greater than zero"))
        }

        // Price
        let priceStr = cell(.pricePerShare) ?? ""
        let price: Decimal
        if action == .split {
            price = 0
        } else if let p = Decimal(string: priceStr), p >= 0 {
            price = p
        } else if action == .dividend || action == .drip {
            price = 0
        } else {
            return .failure(ImportIssue(severity: .error, rowIndex: rowIndex,
                message: "Price cannot be negative"))
        }

        let costBasis    = cell(.costBasis).flatMap { Decimal(string: $0) }
        let fee          = cell(.fee).flatMap { Decimal(string: $0) } ?? 0
        let notes        = cell(.notes)
        let sector       = cell(.sector)
        let assetTypeStr = cell(.assetType) ?? ""
        let detectedType = parseAssetType(assetTypeStr) ?? ImportedTransaction.detectAssetType(symbol: symbol)

        // Split ratio from notes
        var splitRatio: ImportedTransaction.SplitRatio?
        if action == .split {
            splitRatio = parseSplitRatio(notes ?? qtyStr)
        }

        return .success(ImportedTransaction(
            rowIndex: rowIndex,
            symbol: symbol,
            tradeDate: tradeDate,
            action: action,
            quantity: quantity,
            pricePerShare: price,
            costBasis: costBasis,
            detectedAssetType: detectedType,
            sector: sector,
            fee: fee,
            notes: notes,
            splitRatio: splitRatio
        ))
    }

    // MARK: - Row Validation

    private static func validateRow(_ tx: ImportedTransaction) -> [ImportIssue] {
        var issues: [ImportIssue] = []
        if tx.tradeDate > Date() {
            issues.append(ImportIssue(severity: .warning, rowIndex: tx.rowIndex,
                message: "Trade date \(tx.tradeDate.formatted(.dateTime.month(.abbreviated).day().year())) is in the future"))
        }
        if let cb = tx.costBasis, tx.quantity > 0, tx.pricePerShare > 0 {
            let expected = (tx.quantity * tx.pricePerShare).rounded(to: 2)
            if abs(cb - expected) > Decimal(string: "0.05")! {
                issues.append(ImportIssue(severity: .warning, rowIndex: tx.rowIndex,
                    message: "\(tx.symbol): cost basis \(cb.asCurrency) ≠ Qty × Price \(expected.asCurrency) — may include fees"))
            }
        }
        return issues
    }

    private static func validateCrossRows(_ transactions: [ImportedTransaction]) -> [ImportIssue] {
        var issues: [ImportIssue] = []
        var seen: Set<String> = []
        var buySymbols: Set<String> = []

        for tx in transactions where tx.action == .buy || tx.action == .transferIn {
            buySymbols.insert(tx.symbol)
        }

        for tx in transactions {
            // Duplicate detection
            let key = "\(tx.symbol)-\(tx.tradeDate.timeIntervalSince1970)-\(tx.quantity)-\(tx.pricePerShare)"
            if seen.contains(key) {
                issues.append(ImportIssue(severity: .warning, rowIndex: tx.rowIndex,
                    message: "Possible duplicate: \(tx.symbol) on \(tx.tradeDate.formatted(.dateTime.month(.abbreviated).day().year())) same qty/price"))
            }
            seen.insert(key)

            // Sell without buy
            if tx.action == .sell && !buySymbols.contains(tx.symbol) {
                issues.append(ImportIssue(severity: .warning, rowIndex: tx.rowIndex,
                    message: "\(tx.symbol): no matching buy lot found — lot may predate app tracking"))
            }
        }
        return issues
    }

    // MARK: - Date Parsing

    static func parseDate(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd", "MM/dd/yyyy", "M/d/yyyy", "MM-dd-yyyy",
                    "yyyy/MM/dd", "MMM d, yyyy", "d MMM yyyy", "MMMM d, yyyy"] {
            formatter.dateFormat = fmt
            if let date = formatter.date(from: s) { return date }
        }
        return nil
    }

    // MARK: - RFC 4180 CSV Row Parser

    static func parseCSVRow(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var idx = line.startIndex

        while idx < line.endIndex {
            let c = line[idx]
            if c == "\"" {
                let next = line.index(after: idx)
                if inQuotes && next < line.endIndex && line[next] == "\"" {
                    current.append("\"")
                    idx = line.index(after: next)
                    continue
                }
                inQuotes.toggle()
            } else if c == "," && !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(c)
            }
            idx = line.index(after: idx)
        }
        fields.append(current)
        return fields
    }

    // MARK: - Helpers

    private static func parseAssetType(_ raw: String) -> AssetType? {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "stock", "equity", "us equity": return .stock
        case "etf", "fund":                  return .etf
        case "crypto", "cryptocurrency":     return .crypto
        case "option", "options":            return .options
        case "treasury", "t-bill", "tbill":  return .treasury
        default:                             return nil
        }
    }

    private static func parseSplitRatio(_ text: String) -> ImportedTransaction.SplitRatio? {
        for pattern in [#"(\d+)\s*:\s*(\d+)"#, #"(\d+)\s+for\s+(\d+)"#, #"(\d+)-for-(\d+)"#] {
            guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { continue }
            let parts = text[range]
                .components(separatedBy: CharacterSet.decimalDigits.inverted)
                .compactMap(Int.init)
            if parts.count >= 2 {
                return ImportedTransaction.SplitRatio(numerator: parts[0], denominator: parts[1])
            }
        }
        return nil
    }
}
