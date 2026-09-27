//
//  SessionFactory.swift
//  ExGhostty_iPad
//
//  Builds an SSHSession from a saved connection config, resolving
//  credentials (Keychain password / imported private key) and the
//  optional jump host.
//

import Foundation
import NIOSSH

enum SessionFactory {
    static func makeSession(for config: SSHConnectionConfig) -> SSHSession {
        let session = SSHSession(
            config: config,
            password: resolvePassword(for: config),
            privateKey: resolvePrivateKey(for: config)
        )

        if let jumpID = config.jumpHostID,
           let jumpConfig = ConnectionStore.shared.connections.first(where: { $0.id == jumpID }) {
            session.jump = SSHSession.JumpSpec(
                config: jumpConfig,
                password: resolvePassword(for: jumpConfig),
                privateKey: resolvePrivateKey(for: jumpConfig)
            )
        }

        return session
    }

    private static func resolvePassword(for config: SSHConnectionConfig) -> String? {
        // Password acts as fallback even in key mode (some servers require both).
        KeychainHelper.password(for: config.id)
    }

    private static func resolvePrivateKey(for config: SSHConnectionConfig) -> NIOSSHPrivateKey? {
        // A nil passphrase behaves exactly like before (unencrypted keys);
        // jump-host credentials go through this same function, so encrypted
        // jump keys are supported too.
        guard config.authMode == .key,
              let keyID = config.keyID,
              let text = SSHKeyStore.shared.keyText(for: keyID),
              let parsed = try? SSHKeyParser.parse(
                  text, passphrase: KeychainHelper.keyPassphrase(for: config.id)
              ) else {
            return nil
        }
        return parsed.key
    }
}
