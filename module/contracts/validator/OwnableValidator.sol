// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.23;

import { ERC7579ValidatorBase } from "../module-bases/ERC7579ValidatorBase.sol";
import { PackedUserOperation } from
    "@account-abstraction/contracts/core/UserOperationLib.sol";
import { SignatureCheckerLib } from "solady/utils/SignatureCheckerLib.sol";
import { SentinelList4337Lib, SENTINEL } from "sentinellist/SentinelList4337.sol";
import { LibSort } from "solady/utils/LibSort.sol";
import { CheckSignatures } from "checknsignatures/CheckNSignatures.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";

import {BasePluginWithEventMetadata, PluginMetadata} from "../module-bases/Base.sol";


/**
 * @title OwnableValidator
 * @dev Module that allows users to designate EOA owners that can validate transactions using a
 * threshold
 * @author Rhinestone
 */
contract OwnableValidator is ERC7579ValidatorBase, BasePluginWithEventMetadata {
    using LibSort for *;
    using SignatureCheckerLib for address;
    using SentinelList4337Lib for SentinelList4337Lib.SentinelList;

    /*//////////////////////////////////////////////////////////////////////////
                            CONSTANTS & STORAGE
    //////////////////////////////////////////////////////////////////////////*/

    error ThresholdNotSet();
    error InvalidThreshold();
    error NotSortedAndUnique();
    error MaxOwnersReached();
    error InvalidOwner(address owner);

    // maximum number of owners per account
    uint256 constant MAX_OWNERS = 32;

    // account => owners
    SentinelList4337Lib.SentinelList owners;
    // account => threshold
    mapping(address account => uint256) public threshold;
    // account => ownerCount
    mapping(address => uint256) public ownerCount;


    constructor(
    )
    BasePluginWithEventMetadata(
            PluginMetadata({
                name: "OwnableValidator",
                version: "1.0.0",
                requiresRootAccess: false,
                iconUrl: "https://safe-validator.zenguard.xyz/assets/key-346bc9bd.svg",
                appUrl: "https://safe-validator.zenguard.xyz",
                hook: false
            })
        )
    {

    }

    /*//////////////////////////////////////////////////////////////////////////
                                     CONFIG
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * Initializes the module with the threshold and owners
     * @dev data is encoded as follows: abi.encode(threshold, owners)
     *
     * @param data encoded data containing the threshold and owners
     */
    function onInstall(bytes calldata data) external override {
        // decode the threshold and owners
        (uint256 _threshold, address[] memory _owners) = abi.decode(data, (uint256, address[]));

        // check that owners are sorted and uniquified
        if (!_owners.isSortedAndUniquified()) {
            revert NotSortedAndUnique();
        }

        // make sure the threshold is set
        if (_threshold == 0) {
            revert ThresholdNotSet();
        }

        // make sure the threshold is less than the number of owners
        uint256 ownersLength = _owners.length;
        if (ownersLength < _threshold) {
            revert InvalidThreshold();
        }

        // cache the account address
        address account = msg.sender;

        // set threshold
        threshold[account] = _threshold;

        // check if max owners is reached
        if (ownersLength > MAX_OWNERS) {
            revert MaxOwnersReached();
        }

        // set owner count
        ownerCount[account] = ownersLength;

        // initialize the owner list
        owners.init(account);

        // add owners to the list
        for (uint256 i = 0; i < ownersLength; i++) {
            address _owner = _owners[i];
            if (_owner == address(0)) {
                revert InvalidOwner(_owner);
            }
            owners.push(account, _owner);
        }
    }

    /**
     * Handles the uninstallation of the module and clears the threshold and owners
     * @dev the data parameter is not used
     */
    function onUninstall(bytes calldata) external override {
        // cache the account address
        address account = msg.sender;

        // clear the owners
        owners.popAll(account);

        // remove the threshold
        threshold[account] = 0;

        // remove the owner count
        ownerCount[account] = 0;
    }

    /**
     * Checks if the module is initialized
     *
     * @param smartAccount address of the smart account
     * @return true if the module is initialized, false otherwise
     */
    function isInitialized(address smartAccount) public view returns (bool) {
        return threshold[smartAccount] != 0;
    }

    /**
     * Sets the threshold for the account
     * @dev the function will revert if the module is not initialized
     *
     * @param _threshold uint256 threshold to set
     */
    function setThreshold(uint256 _threshold) external {
        // cache the account address
        address account = msg.sender;
        // check if the module is initialized and revert if it is not
        if (!isInitialized(account)) revert NotInitialized(account);

        // make sure that the threshold is set
        if (_threshold == 0) {
            revert InvalidThreshold();
        }

        // make sure the threshold is less than the number of owners
        if (ownerCount[account] < _threshold) {
            revert InvalidThreshold();
        }

        // set the threshold
        threshold[account] = _threshold;
    }

    /**
     * Adds an owner to the account
     * @dev will revert if the owner is already added
     *
     * @param owner address of the owner to add
     */
    function addOwner(address owner) external {
        // cache the account address
        address account = msg.sender;
        // check if the module is initialized and revert if it is not
        if (!isInitialized(account)) revert NotInitialized(account);

        // revert if the owner is address(0)
        if (owner == address(0)) {
            revert InvalidOwner(owner);
        }

        // check if max owners is reached
        if (ownerCount[account] >= MAX_OWNERS) {
            revert MaxOwnersReached();
        }

        // increment the owner count
        ownerCount[account]++;

        // add the owner to the linked list
        owners.push(account, owner);
    }

    /**
     * Removes an owner from the account
     * @dev will revert if the owner is not added or the previous owner is invalid
     *
     * @param prevOwner address of the previous owner
     * @param owner address of the owner to remove
     */
    function removeOwner(address prevOwner, address owner) external {
        // remove the owner
        owners.pop(msg.sender, prevOwner, owner);

        // decrement the owner count
        ownerCount[msg.sender]--;
    }

    /**
     * Returns the owners of the account
     *
     * @param account address of the account
     *
     * @return ownersArray array of owners
     */
    function getOwners(address account) external view returns (address[] memory ownersArray) {
        // get the owners from the linked list
        (ownersArray,) = owners.getEntriesPaginated(account, SENTINEL, MAX_OWNERS);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     MODULE LOGIC
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * Validates a user operation
     *
     * @param userOp PackedUserOperation struct containing the UserOperation
     * @param userOpHash bytes32 hash of the UserOperation
     *
     * @return ValidationData the UserOperation validation result
     */
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    )
        external
        view
        override
        returns (ValidationData)
    {
        // validate the signature with the config
        bool isValid = _validateSignatureWithConfig(userOp.sender, userOpHash, userOp.signature);

        // return the result
        if (isValid) {
            return VALIDATION_SUCCESS;
        }
        return VALIDATION_FAILED;
    }

    /**
     * Validates an ERC-1271 signature with the sender
     *
     * @param hash bytes32 hash of the data
     * @param data bytes data containing the signatures
     *
     * @return bytes4 EIP1271_SUCCESS if the signature is valid, EIP1271_FAILED otherwise
     */
    function isValidSignatureWithSender(
        address,
        bytes32 hash,
        bytes calldata data
    )
        external
        view
        override
        returns (bytes4)
    {
        // validate the signature with the config
        bool isValid = _validateSignatureWithConfig(msg.sender, hash, data);

        // return the result
        if (isValid) {
            return EIP1271_SUCCESS;
        }
        return EIP1271_FAILED;
    }

    /**
     * Validates a signature with the data (stateless validation)
     *
     * @param hash bytes32 hash of the data
     * @param signature bytes data containing the signatures
     * @param data bytes data containing the data
     *
     * @return bool true if the signature is valid, false otherwise
     */
    function validateSignatureWithData(
        bytes32 hash,
        bytes calldata signature,
        bytes calldata data
    )
        external
        view
        returns (bool)
    {
        // decode the threshold and owners
        (uint256 _threshold, address[] memory _owners) = abi.decode(data, (uint256, address[]));

        // check that owners are sorted and uniquified
        if (!_owners.isSortedAndUniquified()) {
            return false;
        }

        // check that threshold is set
        if (_threshold == 0) {
            return false;
        }

        // recover the signers from the signatures
        address[] memory signers = CheckSignatures.recoverNSignatures(
            ECDSA.toEthSignedMessageHash(hash), signature, _threshold
        );

        // sort and uniquify the signers to make sure a signer is not reused
        signers.sort();
        signers.uniquifySorted();

        // check if the signers are owners
        uint256 validSigners;
        uint256 signersLength = signers.length;
        for (uint256 i = 0; i < signersLength; i++) {
            (bool found,) = _owners.searchSorted(signers[i]);
            if (found) {
                validSigners++;
            }
        }

        // check if the threshold is met and return the result
        if (validSigners >= _threshold) {
            // if the threshold is met, return true
            return true;
        }
        // if the threshold is not met, false
        return false;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     INTERNAL
    //////////////////////////////////////////////////////////////////////////*/

    function _validateSignatureWithConfig(
        address account,
        bytes32 hash,
        bytes calldata data
    )
        internal
        view
        returns (bool)
    {
        // get the threshold and check that its set
        uint256 _threshold = threshold[account];
        if (_threshold == 0) {
            return false;
        }

        // recover the signers from the signatures
        address[] memory signers =
            CheckSignatures.recoverNSignatures(ECDSA.toEthSignedMessageHash(hash), data, _threshold);

        // sort and uniquify the signers to make sure a signer is not reused
        signers.sort();
        signers.uniquifySorted();

        // check if the signers are owners
        uint256 validSigners;
        uint256 signersLength = signers.length;
        for (uint256 i = 0; i < signersLength; i++) {
            if (owners.contains(account, signers[i])) {
                validSigners++;
            }
        }

        // check if the threshold is met and return the result
        if (validSigners >= _threshold) {
            // if the threshold is met, return true
            return true;
        }
        // if the threshold is not met, return false
        return false;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     METADATA
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * Returns the type of the module
     *
     * @param typeID type of the module
     *
     * @return true if the type is a module type, false otherwise
     */
    function isModuleType(uint256 typeID) external pure override returns (bool) {
        return typeID == TYPE_VALIDATOR;
    }

}