import Foundation
import CoreData

// MARK: - Export Service

/// Generates a CSV export of all transactions in the import-compatible format.
/// The output is a full round-trip: Export → edit in Excel → re-import.

enum ExportService {

    static func exportCSV(context: NSManagedObjectContext,
                          taxProfile: TaxProfile?) throws -> URL {
        let rows = try buildRows(context: context)
        let header = buildHeader(taxProfile: taxProfile)
        let columnRow = "Symbol,TradeDate,Action,Quantity,PricePerShare,CostBasis,AssetType,Sector,Fee,Notes"

        var lines: [String] = []
        lines.append(contentsOf: header)
        lines.append(columnRow)
        lines.append(contentsOf: rows)

        let csv = lines.joined(separator: "\n")
        let url = tempFileURL()
        try csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Header

    private static func buildHeader(taxProfile: TaxProfile?) -> [String] {
        let dateStr = DateFormatter.exportDate.string(from: Date())
        var lines = [
            "# PortfolioApp Export — \(dateStr)",
            "# ESTIMATED TAX DATA - FOR REFERENCE ONLY",
            "# Cost basis reflects user-entered data, not broker confirmation.",
            "# Consult a tax professional before filing. Not tax advice.",
        ]
        if let profile = taxProfile, profile.isComplete {
            let income = profile.annualIncome.asCurrencyCompact
            lines.append("# Tax profile: \(profile.filingStatus.displayName) | \(income) income | \(profile.state)\(profile.city.isEmpty ? "" : " / \(profile.city)")")
        }
        lines.append("#")
        return lines
    }

    // MARK: - Rows

    private static func buildRows(context: NSManagedObjectContext) throws -> [String] {
        // Fetch all holdings for symbol/assetType/sector lookup
        let holdingReq = NSFetchRequest<Holding>(entityName: "Holding")
        let holdings = try context.fetch(holdingReq)
        let holdingMap = Dictionary(uniqueKeysWithValues: holdings.map { ($0.id, $0) })

        // Fetch all non-deleted transactions sorted by tradeDate
        let txReq = NSFetchRequest<Transaction>(entityName: "Transaction")
        txReq.predicate = NSPredicate(format: "isSoftDeleted == NO")
        txReq.sortDescriptors = [
            NSSortDescriptor(key: "tradeDate", ascending: true),
            NSSortDescriptor(key: "createdAt", ascending: true)
        ]
        let transactions = try context.fetch(txReq)

        return transactions.compactMap { tx -> String? in
            guard let holding = holdingMap[tx.holdingId] else { return nil }
            return csvRow(tx: tx, holding: holding)
        }
    }

    private static func csvRow(tx: Transaction, holding: Holding) -> String {
        let symbol    = escape(holding.symbol)
        let date      = DateFormatter.exportDate.string(from: tx.tradeDate ?? Date())
        let action    = tx.type.exportAction
        let qty       = tx.quantity > 0 ? formatDecimal(tx.quantity) : ""
        let price     = tx.pricePerShare > 0 ? formatDecimal(tx.pricePerShare) : ""
        let costBasis = tx.totalAmount > 0 ? formatDecimal(tx.totalAmount) : ""
        let assetType = holding.assetType.exportName
        let sector    = escape(holding.sector ?? "")
        let fee       = tx.fee > 0 ? formatDecimal(tx.fee) : ""
        let notes     = escape(tx.notes ?? "")

        return [symbol, date, action, qty, price, costBasis, assetType, sector, fee, notes]
            .joined(separator: ",")
    }

    // MARK: - Helpers

    private static func escape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func formatDecimal(_ value: Decimal) -> String {
        let ns = value as NSDecimalNumber
        return ns.stringValue
    }

    private static func tempFileURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let filename = "PortfolioApp_Export_\(formatter.string(from: Date())).csv"
        return FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    }
}

// MARK: - Extensions

private extension DateFormatter {
    static let exportDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

private extension TransactionType {
    var exportAction: String {
        switch self {
        case .buy:          return "BUY"
        case .sell:         return "SELL"
        case .dividend:     return "DIVIDEND"
        case .drip:         return "DRIP"
        case .split:        return "SPLIT"
        case .transferIn:   return "TRANSFER_IN"
        case .transferOut:  return "TRANSFER_OUT"
        case .btc:          return "BUY"   // Buy-to-Close maps to BUY on re-import
        case .stc:          return "SELL"  // Sell-to-Close maps to SELL on re-import
        }
    }
}

private extension AssetType {
    var exportName: String {
        switch self {
        case .stock:    return "Stock"
        case .etf:      return "ETF"
        case .crypto:   return "Crypto"
        case .options:  return "Option"
        case .cash:     return "Cash"
        case .mmf:      return "MMF"
        case .tbill:    return "T-Bill"
        case .tnote:    return "T-Note"
        case .tbond:    return "T-Bond"
        case .tips:     return "TIPS"
        case .ibond:    return "I-Bond"
        }
    }
}
