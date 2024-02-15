// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

/// @title Cyan Admin Wallet
/// @author Bulgantamir Gankhuyag - <bulgaa@usecyan.com>
/// @author Naranbayar Uuganbayar - <naba@usecyan.com>
contract CyanAdminWallet is AccessControlUpgradeable {
    struct Call {
        address to;
        uint256 value;
        bytes data;
    }
    // bytes4(keccak256("isValidSignature(bytes32,bytes)"));
    bytes4 internal constant ERC1271_MAGIC_VALUE = 0x1626ba7e;

    // bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)"));
    bytes4 private constant ERC1155_RECEIVED = 0xf23a6e61;

    // bytes4(keccak256("onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)"));
    bytes4 private constant ERC1155_BATCH_RECEIVED = 0xbc197c81;

    // bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"));
    bytes4 private constant ERC721_RECEIVED = 0x150b7a02;

    bytes32 public constant CYAN_ROLE = keccak256("CYAN_ROLE");

    function initialize(address _cyanSuperAdmin, address _cyanAdmin) external initializer {
        require(_cyanSuperAdmin != address(0), "Invalid address");
        require(_cyanAdmin != address(0), "Invalid address");

        _setupRole(DEFAULT_ADMIN_ROLE, _cyanSuperAdmin);
        _setupRole(CYAN_ROLE, _cyanAdmin);

        __AccessControl_init();
    }

    function executeBatch(Call[] calldata data) external payable onlyRole(CYAN_ROLE) {
        for (uint8 i = 0; i < data.length; ++i) {
            execute(data[i].to, data[i].value, data[i].data);
        }
    }

    /// @notice Main transaction handling method of the wallet.
    ///      Note: All the non-core transactions go through this method.
    /// @param to Destination contract address.
    /// @param value Native token value of the transaction.
    /// @param data Data payload of the transaction.
    /// @return result of the transaction.
    function execute(
        address to,
        uint256 value,
        bytes memory data
    ) public payable onlyRole(CYAN_ROLE) returns (bytes memory result) {
        require(address(this).balance >= value, "Not enough balance.");
        assembly {
            let success := call(gas(), to, value, add(data, 0x20), mload(data), 0, 0)

            mstore(result, returndatasize())
            returndatacopy(add(result, 0x20), 0, returndatasize())

            if eq(success, 0) {
                revert(add(result, 0x20), returndatasize())
            }
        }
    }

    /// @notice Return whether the signature provided is valid for the provided data.
    /// @param data Data signed on the behalf of the wallet.
    /// @param signature Signature byte array associated with the data.
    /// @return magicValue Returns a magic value (0x1626ba7e) if the given signature is correct.
    function isValidSignature(bytes32 data, bytes calldata signature) external view returns (bytes4 magicValue) {
        require(signature.length == 65, "Invalid signature length.");
        address signer = recoverSigner(data, signature);
        require(hasRole(CYAN_ROLE, signer), "Forbidden");
        return ERC1271_MAGIC_VALUE;
    }

    /// @notice Recover signer address from signature.
    /// @param signedHash Arbitrary length data signed on the behalf of the wallet.
    /// @param signature Signature byte array associated with signedHash.
    /// @return Recovered signer address.
    function recoverSigner(bytes32 signedHash, bytes memory signature) private pure returns (address) {
        uint8 v;
        bytes32 r;
        bytes32 s;
        // we jump 32 (0x20) as the first slot of bytes contains the length
        // we jump 65 (0x41) per signature
        // for v we load 32 bytes ending with v (the first 31 come from s) then apply a mask
        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }
        require(v == 27 || v == 28, "Bad v value in signature.");

        address recoveredAddress = ecrecover(signedHash, v, r, s);
        require(recoveredAddress != address(0), "ecrecover returned 0.");
        return recoveredAddress;
    }

    /// @notice Allows the wallet to receive an ERC721 tokens.
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return ERC721_RECEIVED;
    }

    /// @notice Allows the wallet to receive an ERC1155 token.
    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return ERC1155_RECEIVED;
    }

    /// @notice Allows the wallet to receive an ERC1155 tokens.
    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return ERC1155_BATCH_RECEIVED;
    }

    /// @notice Allows the wallet to receive native token.
    receive() external payable {}
}
