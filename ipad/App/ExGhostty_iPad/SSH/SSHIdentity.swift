//
//  SSHIdentity.swift
//  iOSTerminal
//
//  "User Identity": after logging in as the connection's user, switch to a
//  configured target user via sudo. Ported from ExGhostty (macOS).
//

import Foundation

enum SSHIdentity {
    /// A configured identity: target username + sudo password used to answer
    /// the sudo prompt (nil = NOPASSWD or not provided).
    struct Identity: Hashable {
        let username: String
        let sudoPassword: String?
    }

    /// Wraps a one-shot remote command so it runs as the identity's user.
    /// Returns the command unchanged when no identity applies.
    static func wrap(remoteCommand: String, as identity: Identity?, loginUsername: String) -> String {
        guard let identity, identity.username != loginUsername else { return remoteCommand }
        let quotedCommand = shellQuote(remoteCommand)
        let quotedUser = shellQuote(identity.username)
        if let password = identity.sudoPassword, !password.isEmpty {
            return "echo \(shellQuote(password)) | sudo -S -p '' -u \(quotedUser) sh -c \(quotedCommand)"
        }
        return "sudo -n -u \(quotedUser) sh -c \(quotedCommand)"
    }

    /// Interactive-shell switch command: `exec` replaces the login shell so
    /// exiting the target user ends the SSH session instead of falling back.
    static func shellSwitchCommand(as identity: Identity) -> String {
        "exec sudo -k su - \(shellQuote(identity.username))"
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
