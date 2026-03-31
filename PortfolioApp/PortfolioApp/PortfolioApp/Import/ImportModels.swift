import Foundation

// MARK: - Import Action

enum ImportAction {
    case buy, sell, dividend, drip, split, transferIn, transferOut

    init?(rawInput: String) {
        let n = rawInput.uppercased().trimmingCharacters(in: .whitespaces)
        let map: [String: ImportAction] = [
            "BUY": .buy, "PURCHASE": .buy, "BOUGHT": .buy,
            "SELL": .sell, "SALE": .sell, "SOLD": .sell,
            "DIVIDEND": .dividend, "DIV": .dividend, "INCOME": .dividend,
            "DRIP": .drip, "REINVESTMENT": .drip, "REINVEST": .drip,
            "SPLIT": .split,
            "TRANSFER_IN": .transferIn, "TRANSFERIN": .transferIn,
            "TRANSFER_OUT": .transferOut, "TRANSFEROUT": .transferOut
        ]
        guard let a = map[n] else { return nil }
        self = a
    }

    var transactionType: TransactionType {
        switch self {
        case .buy:         return .buy
        case .sell:        return .sell
        case .dividend:    return .dividend
        case .drip:        return .drip
        case .split:       return .split
        case .transferIn:  return .transferIn
        case .transferOut: return .transferOut
        }
    }
}

// MARK: - Parsed Row

struct ImportedTransaction {
    let rowIndex: Int          // 1-based, for error messages
    let symbol: String
    let tradeDate: Date
    let action: ImportAction
    let quantity: Decimal
    let pricePerShare: Decimal
    let costBasis: Decimal?
    let detectedAssetType: AssetType?
    let sector: String?
    let fee: Decimal
    let notes: String?
    let splitRatio: SplitRatio?

    struct SplitRatio {
        let numerator: Int
        let denominator: Int
        var multiplier: Decimal { Decimal(numerator) / Decimal(denominator) }
        var displayString: String { "\(numerator):\(denominator)" }
    }

    var effectiveCostBasis: Decimal {
        costBasis ?? (quantity * pricePerShare).rounded(to: 2)
    }

    var effectiveAssetType: AssetType {
        detectedAssetType ?? ImportedTransaction.detectAssetType(symbol: symbol)
    }

    static func detectAssetType(symbol: String) -> AssetType {
        let s = symbol.uppercased()
        let cryptoTickers: Set<String> = [
            "BTC","ETH","SOL","ADA","MATIC","DOT","AVAX","LINK","UNI","ATOM",
            "DOGE","XRP","LTC","BCH","XLM","ALGO","VET","FIL","TRX","NEAR"
        ]
        if cryptoTickers.contains(s) || s.hasSuffix("-USD") || s.hasSuffix("-USDT") {
            return .crypto
        }
        // Option pattern: "AAPL 150C" or "SPX 5500C 2026-01-17"
        if s.range(of: #"^[A-Z]+\s+\d+[CP]"#, options: .regularExpression) != nil {
            return .options
        }
        return .stock
    }
}

// MARK: - Validation Issue

struct ImportIssue: Error {
    enum Severity { case error, warning }
    let severity: Severity
    let rowIndex: Int?   // nil = file-level issue
    let message: String

    var isError: Bool { severity == .error }
}

// MARK: - Parse Result

struct ImportParseResult {
    let transactions: [ImportedTransaction]
    let issues: [ImportIssue]

    var errors: [ImportIssue]   { issues.filter { $0.isError } }
    var warnings: [ImportIssue] { issues.filter { !$0.isError } }
    var hasErrors: Bool { !errors.isEmpty }

    var uniqueSymbols: Set<String> { Set(transactions.map(\.symbol)) }
    var splitCount: Int  { transactions.filter { $0.action == .split }.count }
    var dripCount: Int   { transactions.filter { $0.action == .drip }.count }
    var symbolCount: Int { uniqueSymbols.count }
}

// MARK: - CSV Column Field

enum ImportField: String, CaseIterable, Hashable {
    case symbol        = "Symbol"
    case tradeDate     = "TradeDate"
    case action        = "Action"
    case quantity      = "Quantity"
    case pricePerShare = "PricePerShare"
    case costBasis     = "CostBasis"
    case assetType     = "AssetType"
    case sector        = "Sector"
    case fee           = "Fee"
    case notes         = "Notes"

    var isRequired: Bool {
        switch self {
        case .symbol, .tradeDate, .action, .quantity, .pricePerShare: return true
        default: return false
        }
    }

    static let synonyms: [String: ImportField] = [
        "SYMBOL": .symbol, "TICKER": .symbol, "STOCK": .symbol, "ASSET": .symbol, "SECURITY": .symbol,
        "TRADEDATE": .tradeDate, "DATE": .tradeDate, "TRADE DATE": .tradeDate,
        "TRANSACTION DATE": .tradeDate, "PURCHASE DATE": .tradeDate,
        "ACTION": .action, "TYPE": .action, "TRANSACTION TYPE": .action, "ACTIVITY": .action,
        "QUANTITY": .quantity, "SHARES": .quantity, "UNITS": .quantity, "QTY": .quantity,
        "PRICEPERSHARE": .pricePerShare, "PRICE": .pricePerShare, "UNIT PRICE": .pricePerShare,
        "PRICE PER SHARE": .pricePerShare, "COST PER SHARE": .pricePerShare,
        "COSTBASIS": .costBasis, "TOTAL COST": .costBasis, "TOTAL AMOUNT": .costBasis,
        "COST BASIS": .costBasis, "BASIS": .costBasis,
        "ASSETTYPE": .assetType, "ASSET TYPE": .assetType,
        "SECTOR": .sector, "INDUSTRY": .sector,
        "FEE": .fee, "COMMISSION": .fee, "BROKERAGE FEE": .fee,
        "NOTES": .notes, "NOTE": .notes, "COMMENT": .notes, "DESCRIPTION": .notes
    ]

    static func detect(from header: String) -> ImportField? {
        synonyms[header.trimmingCharacters(in: .whitespaces).uppercased()]
    }
}

// MARK: - CSV Column Mapping

struct CSVColumnMapping {
    var mapping: [Int: ImportField]   // column index → field
    let headers: [String]

    var missingRequired: [ImportField] {
        let mapped = Set(mapping.values)
        return ImportField.allCases.filter { $0.isRequired && !mapped.contains($0) }
    }

    var isComplete: Bool { missingRequired.isEmpty }
}

// MARK: - Conflict

struct ImportConflict {
    let symbol: String
    let existingLotCount: Int
    let incomingTransactionCount: Int
}

// MARK: - Import Conflict Resolution

enum ImportConflictResolution {
    case merge    // Add new lots to existing positions
    case replace  // Soft-delete existing lots, import fresh
}

// MARK: - Import Result

struct ImportResult {
    let sessionId: UUID
    let importedAt: Date
    let fileName: String
    let transactionsImported: Int
    let holdingsCreated: Int
    let holdingsUpdated: Int
    let lotsCreated: Int
    let warnings: [ImportIssue]
    var canUndo: Bool = true
}

// MARK: - Import Format

enum ImportFormat {
    case csv, json, xlsx

    static func detect(from url: URL) -> ImportFormat? {
        switch url.pathExtension.lowercased() {
        case "csv":  return .csv
        case "json": return .json
        case "xlsx": return .xlsx
        default:     return nil
        }
    }
}

// MARK: - Import Error

enum ImportError: LocalizedError {
    case emptyFile
    case unsupportedFormat(String)
    case noMappedColumns
    case missingRequiredColumns([String])
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyFile:
            return "The file is empty or contains only comments."
        case .unsupportedFormat(let ext):
            return "Unsupported format: \(ext). Use CSV or JSON."
        case .noMappedColumns:
            return "Could not detect any column headers. Check the file format."
        case .missingRequiredColumns(let cols):
            return "Missing required columns: \(cols.joined(separator: ", "))"
        case .executionFailed(let msg):
            return "Import failed: \(msg)"
        }
    }
}
