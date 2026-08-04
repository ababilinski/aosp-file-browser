import SwiftUI

struct SearchFilterRows: View {
    @Binding var kindFilter: FileSearchKindFilter
    let effectiveKindFilter: FileSearchKindFilter
    let typedKindFilter: FileSearchKindFilter?
    @Binding var dateFilter: FileSearchDateFilter
    let clearKindFilter: () -> Void

    @State private var showDateFilter = false

    private var showsDateRow: Bool {
        showDateFilter || dateFilter != .any
    }

    var body: some View {
        VStack(spacing: 6) {
            filterRow(
                criterion: "Kind",
                criterionSymbol: "line.3.horizontal.decrease.circle",
                relation: "is",
                trailingButtons: { kindTrailingButtons }
            ) {
                Group {
                    if typedKindFilter != nil {
                        Label(effectiveKindFilter.label, systemImage: effectiveKindFilter.systemImage)
                    } else {
                        Picker("Kind", selection: $kindFilter) {
                            ForEach(FileSearchKindFilter.allCases) { filter in
                                Label(filter.label, systemImage: filter.systemImage).tag(filter)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }
                .disabled(typedKindFilter != nil)
                .help(typedKindFilter == nil ? "Kind: choose the file type to show." : "Kind was typed in the search field. Remove the typed filter to change it here.")

                if typedKindFilter != nil {
                    Text("from search")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if showsDateRow {
                filterRow(
                    criterion: "Last Modified",
                    criterionSymbol: "calendar",
                    relation: "is",
                    trailingButtons: { dateTrailingButtons }
                ) {
                    Picker("Last Modified", selection: $dateFilter) {
                        ForEach(FileSearchDateFilter.allCases) { filter in
                            Text(filter.label).tag(filter)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .help("Last Modified: filter by when Android reports the item was changed.")
                }
            }
        }
        .onAppear {
            if dateFilter != .any {
                showDateFilter = true
            }
        }
    }

    private var kindTrailingButtons: some View {
        HStack(spacing: 6) {
            Button {
                clearKindFilter()
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.borderless)
            .help("Remove Kind filter")

            Button {
                showDateFilter = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .disabled(showsDateRow)
            .help(showsDateRow ? "All available filters are shown." : "Add Last Modified filter")
        }
    }

    private var dateTrailingButtons: some View {
        HStack(spacing: 6) {
            Button {
                dateFilter = .any
                showDateFilter = false
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.borderless)
            .help("Remove Last Modified filter")

            Button {} label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .disabled(true)
            .help("All available filters are shown.")
        }
    }

    private func filterRow<Value: View, TrailingButtons: View>(
        criterion: String,
        criterionSymbol: String,
        relation: String,
        @ViewBuilder trailingButtons: () -> TrailingButtons,
        @ViewBuilder value: () -> Value
    ) -> some View {
        HStack(spacing: 8) {
            Menu {
                Button {} label: {
                    Label(criterion, systemImage: "checkmark")
                }
                .disabled(true)
                if criterion != "Kind" {
                    Button("Kind") {}
                        .disabled(true)
                }
                if criterion != "Last Modified" {
                    Button("Last Modified") {
                        showDateFilter = true
                    }
                }
                Divider()
                Button("Name") {}
                    .disabled(true)
            } label: {
                Label(criterion, systemImage: criterionSymbol)
                    .frame(width: 132, alignment: .leading)
            }
            .help("Filter Criterion: this app supports Kind, Name through the search field, and Last Modified.")

            Text(relation)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            value()
                .frame(minWidth: 150, alignment: .leading)

            Spacer(minLength: 8)

            trailingButtons()
        }
        .font(.callout)
    }
}
