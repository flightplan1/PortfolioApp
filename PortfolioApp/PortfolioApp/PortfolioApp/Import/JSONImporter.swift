import Foundation

struct JSONImporter {

    // MARK: - Decodable Models

    private struct JSONImportFile: Decodable {
        let importVersion: String?
        let transactions: [JSONTransaction]
    }

    private struct JSONTransaction: Decodable {
        let symbol: String
        let tradeDate: String
        let action: String
        let quantity: Double?
        let pricePerShare: Double?
        let costBasis: Double?
        let assetType: String?
        let sector: String?
        let fee: Double?
        let notes: String?
        let splitRatio: JSONSplitRatio?
    }

    private struct JSONSplitRatio: Decodable {
        let numerator: Int
        let denominator: Int
    }

    // MARK: - Parse

    static func parse(url: URL) throws -> ImportParseResult {
        let data = try Data(contentsOf: url)
        let file = try JSONDecoder().decode(JSONImportFile.self, from: data)

        var transactions: [ImportedTransaction] = []
        var issues: [ImportIssue] = []

        for (i, raw) in file.transactions.enumerated() {
            let row = i + 1

            let symbol = raw.symbol.uppercased().trimmingCharacters(in: .whitespaces)
            guard !symbol.isEmpty else {
                issues.append(ImportIssue(severity: .error, rowIndex: row, message: "Symbol is required"))
                continue
            }

            guard let tradeDate = CSVParser.parseDate(raw.tradeDate) else {
                issues.append(ImportIssue(severity: .error, rowIndex: row,
                    message: "Cannot parse date '\(raw.tradeDate)' for \(symbol)"))
                continue
            }

            guard let action = ImportAction(rawInput: raw.action) else {
                issues.append(ImportIssue(severity: .error, rowIndex: row,
                    message: "Unknown action '\(raw.action)' for \(symbol)"))
                continue
            }

            let qty       = raw.quantity.map { Decimal($0) } ?? 0
            let price     = raw.pricePerShare.map { Decimal($0) } ?? 0
            let costBasis = raw.costBasis.map { Decimal($0) }
            let fee       = raw.fee.map { Decimal($0) } ?? 0

            let splitRatio = raw.splitRatio.map {
                ImportedTransaction.SplitRatio(numerator: $0.numerator, denominator: $0.denominator)
            }

            let detectedType: AssetType?
            if let at = raw.assetType { detectedType = parseAssetType(at) } else { detectedType = nil }

            transactions.append(ImportedTransaction(
                rowIndex: row,
                symbol: symbol,
                tradeDate: tradeDate,
                action: action,
                quantity: qty,
                pricePerShare: price,
                costBasis: costBasis,
                detectedAssetType: detectedType,
                sector: raw.sector,
                fee: fee,
                notes: raw.notes,
                splitRatio: splitRatio
            ))
        }

        return ImportParseResult(transactions: transactions, issues: issues)
    }

    private static func parseAssetType(_ raw: String) -> AssetType? {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "stock", "equity":      return .stock
        case "etf":                   return .etf
        case "crypto":                return .crypto
        case "option", "options":     return .options
        case "treasury":              return .treasury
        default:                      return nil
        }
    }
}
