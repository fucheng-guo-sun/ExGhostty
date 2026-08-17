//
//  MainSplitView.swift
//  iOSTerminal
//
//  Root view: left sidebar with the SSH connection list, right side with
//  tabbed terminals (mirrors the ExGhostty macOS layout). The sidebar can
//  collapse to an icon strip, which keeps the terminal usable on narrow
//  (iPhone portrait) screens.
//

import SwiftUI

struct MainSplitView: View {
    @StateObject private var tabStore = TerminalTabStore()
    @State private var sidebarCollapsed = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var sidebarWidth: CGFloat {
        sidebarCollapsed ? 48 : (horizontalSizeClass == .compact ? 240 : 300)
    }

    var body: some View {
        HStack(spacing: 0) {
            ConnectionListView(isCollapsed: $sidebarCollapsed)
                .frame(width: sidebarWidth)
            Divider()
            TerminalTabContainerView()
        }
        .environmentObject(tabStore)
        .background(Color.black)
    }
}

#Preview {
    MainSplitView()
        .preferredColorScheme(.dark)
}
