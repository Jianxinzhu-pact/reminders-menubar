import SwiftUI

@MainActor
struct CreateReminderButton: View {
    @EnvironmentObject var remindersData: RemindersData
    @EnvironmentObject private var copyCoordinator: CopyShortcutCoordinator
    @Environment(\.appHasPopoverOpen) private var appHasPopoverOpen
    @State private var showingCreateView = false
    @State private var copySuspensionId = UUID()

    var body: some View {
        Button {
            showingCreateView = true
        } label: {
            ToolbarButtonLabel {
                HStack {
                    Image(systemName: "plus")
                    Text(String("⌘N"))
                        .foregroundColor(.secondary)
                        .font(.footnote)
                }
                .padding(.trailing, 2)
            }
        }
        .keyboardShortcut("n", modifiers: .command)
        .modifier(ConfirmButtonModifier())
        .help(rmbLocalized(.newReminderButtonHelp))
        .sheet(isPresented: $showingCreateView) {
            ReminderEditView(isPresented: $showingCreateView)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.didCloseNotification)) { _ in
            showingCreateView = false
        }
        .onChange(of: showingCreateView) { isOpen in
            appHasPopoverOpen.wrappedValue = isOpen
            copyCoordinator.setSurfacePresented(isOpen, id: copySuspensionId)
        }
        .onDisappear {
            copyCoordinator.setSurfacePresented(false, id: copySuspensionId)
        }
    }
}

#Preview {
    CreateReminderButton()
        .environmentObject(RemindersData())
        .environmentObject(CopyShortcutCoordinator())
}
