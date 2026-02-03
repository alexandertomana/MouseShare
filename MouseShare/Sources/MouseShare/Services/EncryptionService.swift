import Foundation
import CryptoKit

// MARK: - Encryption Errors

enum EncryptionError: Error, LocalizedError {
    case invalidPassword
    case encryptionFailed
    case decryptionFailed
    case invalidData
    case keyDerivationFailed
    
    var errorDescription: String? {
        switch self {
        case .invalidPassword:
            return "Invalid password"
        case .encryptionFailed:
            return "Encryption failed"
        case .decryptionFailed:
            return "Decryption failed"
        case .invalidData:
            return "Invalid data format"
        case .keyDerivationFailed:
            return "Key derivation failed"
        }
    }
}

// MARK: - Encryption Service

/// Handles AES-GCM encryption for secure network communication
final class EncryptionService {
    
    // MARK: - Properties
    
    private let key: SymmetricKey
    
    // Key derivation parameters
    private static let salt = "MouseShareSalt2024".data(using: .utf8)!
    private static let iterations = 100_000
    
    // MARK: - Initialization
    
    /// Initialize with a password
    init(password: String) throws {
        guard !password.isEmpty else {
            throw EncryptionError.invalidPassword
        }
        
        // Derive key from password using PBKDF2-like approach
        // CryptoKit doesn't have PBKDF2 directly, so we use HKDF
        self.key = try Self.deriveKey(from: password)
    }
    
    /// Initialize with a pre-derived key
    init(key: SymmetricKey) {
        self.key = key
    }
    
    // MARK: - Public Methods
    
    /// Encrypt data
    func encrypt(_ data: Data) throws -> Data {
        do {
            let sealedBox = try AES.GCM.seal(data, using: key)
            
            // Combine nonce + ciphertext + tag
            guard let combined = sealedBox.combined else {
                throw EncryptionError.encryptionFailed
            }
            
            return combined
            
        } catch let error as EncryptionError {
            throw error
        } catch {
            throw EncryptionError.encryptionFailed
        }
    }
    
    /// Decrypt data
    func decrypt(_ data: Data) throws -> Data {
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: data)
            let decrypted = try AES.GCM.open(sealedBox, using: key)
            return decrypted
            
        } catch let error as EncryptionError {
            throw error
        } catch {
            throw EncryptionError.decryptionFailed
        }
    }
    
    /// Generate a random nonce (for testing/debugging)
    static func generateNonce() -> AES.GCM.Nonce? {
        try? AES.GCM.Nonce()
    }
    
    // MARK: - Private Methods
    
    /// Derive a symmetric key from a password using HKDF
    private static func deriveKey(from password: String) throws -> SymmetricKey {
        guard let passwordData = password.data(using: .utf8) else {
            throw EncryptionError.invalidPassword
        }
        
        // Create input key material from password
        let inputKey = SymmetricKey(data: passwordData)
        
        // Use HKDF to derive a 256-bit key
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: salt,
            info: "MouseShare-AES-Key".data(using: .utf8)!,
            outputByteCount: 32
        )
        
        return derivedKey
    }
}

// MARK: - Key Exchange Support

extension EncryptionService {
    
    /// Generate a key pair for key exchange
    static func generateKeyPair() -> (privateKey: Curve25519.KeyAgreement.PrivateKey, publicKey: Curve25519.KeyAgreement.PublicKey) {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        return (privateKey, privateKey.publicKey)
    }
    
    /// Derive shared secret from key exchange
    static func deriveSharedSecret(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKey: Curve25519.KeyAgreement.PublicKey
    ) throws -> SymmetricKey {
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
        
        // Derive symmetric key from shared secret
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: "MouseShare-Session-Key".data(using: .utf8)!,
            outputByteCount: 32
        )
        
        return symmetricKey
    }
    
    /// Create encryption service from key exchange
    static func fromKeyExchange(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKey: Curve25519.KeyAgreement.PublicKey
    ) throws -> EncryptionService {
        let key = try deriveSharedSecret(privateKey: privateKey, peerPublicKey: peerPublicKey)
        return EncryptionService(key: key)
    }
}

// MARK: - Utility Extensions

extension Data {
    /// Convert to hex string (for debugging)
    var hexString: String {
        map { String(format: "%02hhx", $0) }.joined()
    }
}
