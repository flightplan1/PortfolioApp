import SwiftUI
import CoreData
import UniformTypeIdentifiers

// MARK: - Import Flow View
// Multi-step sheet: file picker → column mapping → preview → conflict resolution → split confirmation → result

struct ImportFlowView: View {

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @StateObject private var importService = ImportService()

    @State private var step: ImportStep = .idle
    @State private var selectedURL: URL?
    @State private var showFilePicker = false
    @State private var parseResult: ImportParseResult?
    @State private var csvMapping: CSVColumnMapping?
    @State private var conflicts: [ImportConflict] = []
    @State private var resolution: ImportConflictResolution = .merge
    @State private var skippedSplitRows: Set<Int> = []

    // MARK: - Step

    enum ImportStep {
        case idle
        case loading
        case columnMapping
        case preview
        case conflictResolution
        case splitConfirmation
        case executing
        case result(ImportResult)
        case error(String)
    }

    // MARK: - Body

    var body: some View {
        NavigationView {
            ZStack {
                Color.appBg.ignoresSafeArea()
                stepContent
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if case .result = step { EmptyView() } else {
                        Button("Cancel") { dismiss() }
                            .foregroundColor(.textSub)
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.commaSeparatedText, .json, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                selectedURL = url
                parseFile(url: url)
            case .failure:
                step = .error("Could not open the selected file.")
            }
        }
        .task {
            // Trigger file picker immediately on appear
            showFilePicker = true
        }
    }

    // MARK: - Step Content

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .idle:
            idleView

        case .loading:
            loadingView

        case .columnMapping:
            if let mapping = csvMapping, let result = parseResult {
                ColumnMappingView(
                    mapping: mapping,
                    onConfirm: { updatedMapping in
                        csvMapping = updatedMapping
                        advanceToPreview(result: result)
                    }
                )
            }

        case .preview:
            if let result = parseResult {
                PreviewView(
                    result: result,
                    conflicts: conflicts,
                    onProceed: { advanceFromPreview() }
                )
            }

        case .conflictResolution:
            ImportConflictResolutionView(
                conflicts: conflicts,
                resolution: $resolution,
                onProceed: { advanceFromConflictResolution() }
            )

        case .splitConfirmation:
            if let result = parseResult {
                let splits = result.transactions.filter { $0.action == .split }
                ImportSplitConfirmationView(
                    splits: splits,
                    skippedRows: $skippedSplitRows,
                    onProceed: { executeImport() }
                )
            }

        case .executing:
            executingView

        case .result(let result):
            ResultView(
                result: result,
                importService: importService,
                onDone: { dismiss() },
                onUndo: {
                    importService.undo(context: context)
                    dismiss()
                }
            )

        case .error(let message):
            ErrorView(message: message, onRetry: {
                step = .idle
                showFilePicker = true
            })
        }
    }

    // MARK: - Idle

    private var idleView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 48))
                .foregroundColor(.textMuted)
            Text("Select a file to import")
                .font(AppFont.body(16, weight: .semibold))
                .foregroundColor(.textSub)
            Button("Choose File") { showFilePicker = true }
                .buttonStyle(PrimaryButtonStyle())
            Spacer()
        }
        .padding(32)
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .appBlue))
                .scaleEffect(1.4)
            Text("Parsing file…")
                .font(AppFont.body(14))
                .foregroundColor(.textSub)
            Spacer()
        }
    }

    // MARK: - Executing

    private var executingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .appGreen))
                .scaleEffect(1.4)
            Text("Importing transactions…")
                .font(AppFont.body(14))
                .foregroundColor(.textSub)
            Spacer()
        }
    }

    // MARK: - Navigation Title

    private var navigationTitle: String {
        switch step {
        case .idle, .loading:         return "Import"
        case .columnMapping:          return "Column Mapping"
        case .preview:                return "Preview"
        case .conflictResolution:     return "Existing Data"
        case .splitConfirmation:      return "Confirm Splits"
        case .executing:              return "Importing…"
        case .result:                 return "Import Complete"
        case .error:                  return "Import Error"
        }
    }

    // MARK: - Actions

    private func parseFile(url: URL) {
        step = .loading
        Task {
            do {
                let (result, mapping) = try importService.parse(url: url)
                parseResult = result
                csvMapping = mapping

                // Check if CSV mapping has unmapped required columns
                if let m = mapping, !m.isComplete {
                    step = .columnMapping
                    return
                }

                advanceToPreview(result: result)
            } catch {
                step = .error(error.localizedDescription)
            }
        }
    }

    private func advanceToPreview(result: ImportParseResult) {
        // Detect conflicts (symbols that already have holdings with lots)
        let incomingCounts = Dictionary(
            result.transactions.map { ($0.symbol, 1) },
            uniquingKeysWith: +
        )
        conflicts = importService.detectConflicts(
            symbols: result.uniqueSymbols,
            incomingCounts: incomingCounts,
            context: context
        )
        step = .preview
    }

    private func advanceFromPreview() {
        if conflicts.isEmpty {
            advanceToSplitsOrExecute()
        } else {
            step = .conflictResolution
        }
    }

    private func advanceFromConflictResolution() {
        advanceToSplitsOrExecute()
    }

    private func advanceToSplitsOrExecute() {
        let hasSplits = parseResult?.transactions.contains { $0.action == .split } ?? false
        if hasSplits {
            skippedSplitRows = []
            step = .splitConfirmation
        } else {
            executeImport()
        }
    }

    private func executeImport() {
        guard var result = parseResult else { return }

        // Filter out splits the user chose to skip
        if !skippedSplitRows.isEmpty {
            let filtered = result.transactions.filter { tx in
                tx.action != .split || !skippedSplitRows.contains(tx.rowIndex)
            }
            result = ImportParseResult(transactions: filtered, issues: result.issues)
        }

        step = .executing
        Task {
            do {
                let fileName = selectedURL?.lastPathComponent ?? "import"
                let importResult = try await importService.execute(
                    parseResult: result,
                    resolution: resolution,
                    fileName: fileName,
                    context: context
                )
                step = .result(importResult)
            } catch {
                step = .error(error.localizedDescription)
            }
        }
    }
}

// MARK: - Column Mapping View

private struct ColumnMappingView: View {
    let mapping: CSVColumnMapping
    let onConfirm: (CSVColumnMapping) -> Void

    @State private var currentMapping: [Int: ImportField]

    init(mapping: CSVColumnMapping, onConfirm: @escaping (CSVColumnMapping) -> Void) {
        self.mapping = mapping
        self.onConfirm = onConfirm
        _currentMapping = State(initialValue: mapping.mapping)
    }

    private var updatedMapping: CSVColumnMapping {
        CSVColumnMapping(mapping: currentMapping, headers: mapping.headers)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Info card
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.appGold)
                    Text("Some columns couldn't be auto-detected. Map them below.")
                        .font(AppFont.body(13))
                        .foregroundColor(.textSub)
                }
                .padding(14)
                .background(Color.appGoldDim)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                // Column mapping table
                VStack(spacing: 0) {
                    ForEach(Array(mapping.headers.enumerated()), id: \.offset) { i, header in
                        HStack(spacing: 12) {
                            Text(header)
                                .font(AppFont.mono(12))
                                .foregroundColor(.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Image(systemName: "arrow.right")
                                .font(.system(size: 11))
                                .foregroundColor(.textMuted)

                            Picker("", selection: Binding(
                                get: { currentMapping[i] },
                                set: { currentMapping[i] = $0 }
                            )) {
                                Text("— skip —").tag(Optional<ImportField>.none)
                                ForEach(ImportField.allCases, id: \.self) { field in
                                    Text(field.rawValue)
                                        .tag(Optional(field))
                                }
                            }
                            .tint(.appBlue)
                            .frame(width: 160)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)

                        if i < mapping.headers.count - 1 {
                            Divider().background(Color.appBorder)
                        }
                    }
                }
                .cardStyle()

                // Missing required columns warning
                let missing = updatedMapping.missingRequired
                if !missing.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.appRed)
                        Text("Still missing: \(missing.map(\.rawValue).joined(separator: ", "))")
                            .font(AppFont.body(12))
                            .foregroundColor(.appRed)
                    }
                    .padding(12)
                    .background(Color.appRedDim)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                Button("Continue") { onConfirm(updatedMapping) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!updatedMapping.isComplete)
            }
            .padding(16)
        }
    }
}

// MARK: - Preview View

private struct PreviewView: View {
    let result: ImportParseResult
    let conflicts: [ImportConflict]
    let onProceed: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Stats card
                statsCard

                // Errors (block import)
                if !result.errors.isEmpty {
                    issuesCard(
                        title: "ERRORS — MUST FIX",
                        issues: result.errors,
                        color: .appRed
                    )
                }

                // Warnings
                if !result.warnings.isEmpty {
                    issuesCard(
                        title: "WARNINGS — REVIEW",
                        issues: result.warnings,
                        color: .appGold
                    )
                }

                // Conflicts notice
                if !conflicts.isEmpty {
                    conflictsNotice
                }

                // Proceed button (disabled if errors)
                VStack(spacing: 8) {
                    Button(conflicts.isEmpty ? "Import \(result.transactions.count) Transactions" : "Review Conflicts") {
                        onProceed()
                    }
                    .buttonStyle(PrimaryButtonStyle(color: result.hasErrors ? .textMuted : .appGreen))
                    .disabled(result.hasErrors)

                    if result.hasErrors {
                        Text("Fix all errors before importing.")
                            .font(AppFont.body(12))
                            .foregroundColor(.appRed)
                    }
                }
            }
            .padding(16)
        }
    }

    private var statsCard: some View {
        VStack(spacing: 0) {
            statRow(label: "Transactions", value: "\(result.transactions.count)", color: .appBlue)
            Divider().background(Color.appBorder)
            statRow(label: "Symbols", value: "\(result.symbolCount)", color: .appBlue)
            if result.splitCount > 0 {
                Divider().background(Color.appBorder)
                statRow(label: "Splits detected", value: "\(result.splitCount)", color: .appGold)
            }
            if result.dripCount > 0 {
                Divider().background(Color.appBorder)
                statRow(label: "DRIP transactions", value: "\(result.dripCount)", color: .appGreen)
            }
            if !result.errors.isEmpty {
                Divider().background(Color.appBorder)
                statRow(label: "Errors", value: "\(result.errors.count)", color: .appRed)
            }
            if !result.warnings.isEmpty {
                Divider().background(Color.appBorder)
                statRow(label: "Warnings", value: "\(result.warnings.count)", color: .appGold)
            }
        }
        .cardStyle()
    }

    private func statRow(label: String, value: String, color: Color) -> some View {
        HStack {
            Text(label)
                .font(AppFont.body(14))
                .foregroundColor(.textSub)
            Spacer()
            Text(value)
                .font(AppFont.mono(14, weight: .bold))
                .foregroundColor(color)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func issuesCard(title: String, issues: [ImportIssue], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .sectionTitleStyle()
                .foregroundColor(color)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(issues.prefix(20).enumerated()), id: \.offset) { i, issue in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: issue.isError ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(color)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            if let row = issue.rowIndex {
                                Text("Row \(row)")
                                    .font(AppFont.mono(10, weight: .bold))
                                    .foregroundColor(color.opacity(0.7))
                            }
                            Text(issue.message)
                                .font(AppFont.body(12))
                                .foregroundColor(.textSub)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                    if i < min(issues.count, 20) - 1 {
                        Divider().background(Color.appBorder)
                    }
                }
                if issues.count > 20 {
                    Text("+ \(issues.count - 20) more…")
                        .font(AppFont.body(11))
                        .foregroundColor(.textMuted)
                        .padding(14)
                }
            }
            .background(color.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(color.opacity(0.2), lineWidth: 1))
        }
    }

    private var conflictsNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.merge")
                .foregroundColor(.appBlue)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(conflicts.count) symbol\(conflicts.count == 1 ? "" : "s") already in portfolio")
                    .font(AppFont.body(13, weight: .semibold))
                    .foregroundColor(.textPrimary)
                Text("You'll choose how to handle existing lots on the next screen.")
                    .font(AppFont.body(11))
                    .foregroundColor(.textSub)
            }
        }
        .padding(14)
        .background(Color.appBlueDim)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.appBlueBorder, lineWidth: 1))
    }
}

// MARK: - Conflict Resolution View

private struct ImportConflictResolutionView: View {
    let conflicts: [ImportConflict]
    @Binding var resolution: ImportConflictResolution
    let onProceed: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Explanation
                VStack(alignment: .leading, spacing: 8) {
                    Text("EXISTING DATA FOUND")
                        .sectionTitleStyle()
                    Text("These symbols already have open lots. Choose how to handle them:")
                        .font(AppFont.body(13))
                        .foregroundColor(.textSub)
                }
                .padding(.horizontal, 4)

                // Conflict list
                VStack(spacing: 0) {
                    ForEach(Array(conflicts.enumerated()), id: \.offset) { i, conflict in
                        HStack {
                            Text(conflict.symbol)
                                .font(AppFont.mono(13, weight: .bold))
                                .foregroundColor(.textPrimary)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(conflict.existingLotCount) existing lot\(conflict.existingLotCount == 1 ? "" : "s")")
                                    .font(AppFont.mono(11))
                                    .foregroundColor(.textSub)
                                Text("\(conflict.incomingTransactionCount) incoming")
                                    .font(AppFont.mono(11))
                                    .foregroundColor(.appBlue)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        if i < conflicts.count - 1 {
                            Divider().background(Color.appBorder)
                        }
                    }
                }
                .cardStyle()

                // Resolution picker
                VStack(alignment: .leading, spacing: 12) {
                    Text("RESOLUTION")
                        .sectionTitleStyle()
                        .padding(.horizontal, 4)

                    VStack(spacing: 0) {
                        resolutionOption(
                            title: "Merge",
                            subtitle: "Add imported lots alongside existing ones",
                            icon: "arrow.triangle.merge",
                            color: .appGreen,
                            value: .merge
                        )
                        Divider().background(Color.appBorder)
                        resolutionOption(
                            title: "Replace",
                            subtitle: "Remove existing open lots, import fresh",
                            icon: "arrow.clockwise",
                            color: .appGold,
                            value: .replace
                        )
                    }
                    .cardStyle()
                }

                if resolution == .replace {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.appRed)
                        Text("Replace will soft-delete all open lots for the above symbols. This cannot be undone after the 60s undo window.")
                            .font(AppFont.body(11))
                            .foregroundColor(.appRed)
                    }
                    .padding(12)
                    .background(Color.appRedDim)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                Button("Import with \(resolution == .merge ? "Merge" : "Replace")") {
                    onProceed()
                }
                .buttonStyle(PrimaryButtonStyle(color: resolution == .replace ? .appGold : .appGreen))
            }
            .padding(16)
        }
    }

    private func resolutionOption(
        title: String, subtitle: String, icon: String,
        color: Color, value: ImportConflictResolution
    ) -> some View {
        let isSelected = resolution == value
        return Button {
            resolution = value
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(isSelected ? color : .textMuted)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(AppFont.body(14, weight: .semibold))
                        .foregroundColor(isSelected ? .textPrimary : .textSub)
                    Text(subtitle)
                        .font(AppFont.body(12))
                        .foregroundColor(.textMuted)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? color : .textMuted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Result View

private struct ResultView: View {
    let result: ImportResult
    @ObservedObject var importService: ImportService
    let onDone: () -> Void
    let onUndo: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Success icon
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 52))
                        .foregroundColor(.appGreen)
                    Text("Import Complete")
                        .font(AppFont.display(22))
                        .foregroundColor(.textPrimary)
                }
                .padding(.top, 8)

                // Stats
                VStack(spacing: 0) {
                    resultRow(label: "Transactions imported", value: "\(result.transactionsImported)", color: .appGreen)
                    Divider().background(Color.appBorder)
                    resultRow(label: "Positions created", value: "\(result.holdingsCreated)", color: .appBlue)
                    Divider().background(Color.appBorder)
                    resultRow(label: "Positions updated", value: "\(result.holdingsUpdated)", color: .appBlue)
                    Divider().background(Color.appBorder)
                    resultRow(label: "Lots created", value: "\(result.lotsCreated)", color: .appBlue)
                    if !result.warnings.isEmpty {
                        Divider().background(Color.appBorder)
                        resultRow(label: "Warnings", value: "\(result.warnings.count)", color: .appGold)
                    }
                }
                .cardStyle()

                // Undo countdown
                if importService.undoSecondsRemaining > 0 {
                    undoCard
                }

                Button("Done", action: onDone)
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding(16)
        }
    }

    private func resultRow(label: String, value: String, color: Color) -> some View {
        HStack {
            Text(label)
                .font(AppFont.body(14))
                .foregroundColor(.textSub)
            Spacer()
            Text(value)
                .font(AppFont.mono(14, weight: .bold))
                .foregroundColor(color)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var undoCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Color.appGold.opacity(0.3), lineWidth: 3)
                    .frame(width: 44, height: 44)
                Text("\(importService.undoSecondsRemaining)")
                    .font(AppFont.mono(14, weight: .bold))
                    .foregroundColor(.appGold)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Undo available")
                    .font(AppFont.body(13, weight: .semibold))
                    .foregroundColor(.textPrimary)
                Text("All imported data will be removed.")
                    .font(AppFont.body(11))
                    .foregroundColor(.textSub)
            }
            Spacer()
            Button("Undo", action: onUndo)
                .font(AppFont.body(13, weight: .bold))
                .foregroundColor(.appGold)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.appGoldDim)
                .clipShape(Capsule())
        }
        .padding(14)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.appGoldBorder, lineWidth: 1))
    }
}

// MARK: - Error View

private struct ErrorView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "xmark.circle")
                .font(.system(size: 48))
                .foregroundColor(.appRed)
            Text("Import Failed")
                .font(AppFont.display(18))
                .foregroundColor(.textPrimary)
            Text(message)
                .font(AppFont.body(13))
                .foregroundColor(.textSub)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Try Again", action: onRetry)
                .buttonStyle(PrimaryButtonStyle())
            Spacer()
        }
        .padding(32)
    }
}

// MARK: - Shared Button Style

private struct PrimaryButtonStyle: ButtonStyle {
    var color: Color = .appBlue

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFont.body(15, weight: .semibold))
            .foregroundColor(color == .textMuted ? .textMuted : .white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(color == .textMuted ? Color.surface : color)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(color == .textMuted ? Color.appBorder : Color.clear, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// MARK: - Split Confirmation View

private struct ImportSplitConfirmationView: View {
    let splits: [ImportedTransaction]
    @Binding var skippedRows: Set<Int>
    let onProceed: () -> Void

    @State private var currentIndex: Int = 0

    private var current: ImportedTransaction? {
        guard currentIndex < splits.count else { return nil }
        return splits[currentIndex]
    }

    private var progress: String { "\(currentIndex + 1) of \(splits.count)" }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Progress indicator
                HStack {
                    Text("SPLIT \(currentIndex + 1) OF \(splits.count)")
                        .sectionTitleStyle()
                    Spacer()
                    // Dot indicators
                    HStack(spacing: 6) {
                        ForEach(0..<splits.count, id: \.self) { i in
                            Circle()
                                .fill(dotColor(for: i))
                                .frame(width: 7, height: 7)
                        }
                    }
                }
                .padding(.horizontal, 4)

                if let split = current {
                    splitCard(split)

                    // Action buttons
                    HStack(spacing: 12) {
                        Button {
                            skippedRows.insert(split.rowIndex)
                            advance()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("Skip")
                                    .font(AppFont.body(14, weight: .semibold))
                            }
                            .foregroundColor(.textSub)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.appBorder, lineWidth: 1))
                        }

                        Button {
                            advance()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("Apply Split")
                                    .font(AppFont.body(14, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.appGreen)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                    }

                    Text("Applying adjusts quantity and cost basis on all open lots for \(split.symbol).")
                        .font(AppFont.body(11))
                        .foregroundColor(.textMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
            }
            .padding(16)
        }
    }

    private func splitCard(_ split: ImportedTransaction) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.appGold)
                    .frame(width: 32, height: 32)
                    .background(Color.appGoldDim)
                    .clipShape(RoundedRectangle(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 3) {
                    Text(split.symbol)
                        .font(AppFont.mono(16, weight: .bold))
                        .foregroundColor(.textPrimary)
                    Text("Stock Split")
                        .font(AppFont.body(12))
                        .foregroundColor(.textSub)
                }
                Spacer()
                if let ratio = split.splitRatio {
                    Text(ratio.displayString)
                        .font(AppFont.mono(18, weight: .bold))
                        .foregroundColor(.appGold)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider().background(Color.appBorder)

            // Details
            detailRow(label: "Effective Date",
                      value: split.tradeDate.formatted(.dateTime.month(.wide).day().year()))
            Divider().background(Color.appBorder)

            if let ratio = split.splitRatio {
                detailRow(label: "Ratio", value: "\(ratio.numerator) shares for every \(ratio.denominator)")
                Divider().background(Color.appBorder)
                detailRow(label: "Effect on Qty", value: "× \(ratio.multiplier.asQuantity(maxDecimalPlaces: 2))")
                Divider().background(Color.appBorder)
                detailRow(label: "Effect on Cost Basis", value: "÷ \(ratio.multiplier.asQuantity(maxDecimalPlaces: 2)) per share")
            }

            if let notes = split.notes, !notes.isEmpty {
                Divider().background(Color.appBorder)
                detailRow(label: "Notes", value: notes)
            }
        }
        .cardStyle()
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(AppFont.body(13))
                .foregroundColor(.textSub)
            Spacer()
            Text(value)
                .font(AppFont.mono(13, weight: .semibold))
                .foregroundColor(.textPrimary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func dotColor(for index: Int) -> Color {
        guard index < splits.count else { return .appBorder }
        let rowIndex = splits[index].rowIndex
        if index > currentIndex { return Color.appBorder }
        if skippedRows.contains(rowIndex) { return Color.appRed }
        return Color.appGreen
    }

    private func advance() {
        if currentIndex + 1 < splits.count {
            currentIndex += 1
        } else {
            onProceed()
        }
    }
}

// MARK: - Preview

#Preview {
    ImportFlowView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
        .preferredColorScheme(.dark)
}
