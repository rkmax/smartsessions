// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import "./DataTypes.sol";
import { ISmartSession } from "./ISmartSession.sol";

import { PackedUserOperation } from "modulekit/external/ERC4337.sol";
import { EIP1271_MAGIC_VALUE, IERC1271 } from "module-bases/interfaces/IERC1271.sol";

import "./utils/EnumerableSet4337.sol";
import {
    ModeCode as ExecutionMode,
    ExecType,
    CallType,
    CALLTYPE_BATCH,
    CALLTYPE_SINGLE,
    EXECTYPE_DEFAULT
} from "erc7579/lib/ModeLib.sol";
import { ExecutionLib as ExecutionLib } from "./lib/ExecutionLib.sol";

import { IERC7579Account } from "erc7579/interfaces/IERC7579Account.sol";
import { IAccountExecute } from "modulekit/external/ERC4337.sol";
import { IUserOpPolicy, IActionPolicy } from "contracts/interfaces/IPolicy.sol";

import { PolicyLib } from "./lib/PolicyLib.sol";
import { SignerLib } from "./lib/SignerLib.sol";
import { ConfigLib } from "./lib/ConfigLib.sol";
import { EncodeLib } from "./lib/EncodeLib.sol";

import { HashLib } from "./lib/HashLib.sol";
import { SmartSessionBase } from "./core/SmartSessionBase.sol";
import { SmartSessionERC7739 } from "./core/SmartSessionERC7739.sol";
import { IdLib } from "./lib/IdLib.sol";
import { SmartSessionModeLib } from "./lib/SmartSessionModeLib.sol";

import "forge-std/console2.sol";

/**
 *
 * @title SmartSession
 * @author zeroknots.eth (rhinestone) & Filipp Makarov (biconomy)
 */
contract SmartSession is ISmartSession, SmartSessionBase, SmartSessionERC7739 {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using IdLib for *;
    using HashLib for *;
    using PolicyLib for *;
    using SignerLib for *;
    using ConfigLib for *;
    using ExecutionLib for *;
    using EncodeLib for *;
    using SmartSessionModeLib for SmartSessionMode;

    /**
     * @notice Validates a user operation for ERC4337/ERC7579 compatibility
     * @dev This function is the entry point for validating user operations in SmartSession
     * @dev This function will disect the userop.singature field, and parse out the provided PermissionId, which
     * identifies a
     * unique ID of a dapp for a specific user. n Policies and one Signer contract are mapped to this Id and will be
     * checked. Only UserOps that pass policies and signer checks, are considered valid.
     * Enable Flow:
     *     SmartSessions allows session keys to be created within the "first" UserOp. If the enable flow is chosen, the
     *     EnableSession data, which is packed in userOp.signature is parsed, and stored in the SmartSession storage.
     * @param userOp The user operation to validate
     * @param userOpHash The hash of the user operation
     * @return vd ValidationData containing the validation result
     */
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    )
        external
        override
        returns (ValidationData vd)
    {
        // ensure that userOp.sender == account
        // SmartSession will sstore configs for a certain account,
        // so we have to ensure that unauthorized access is not possible
        address account = userOp.sender;
        if (account != msg.sender) revert InvalidUserOpSender(account);

        // unpacking data packed in userOp.signature
        (SmartSessionMode mode, PermissionId permissionId, bytes calldata packedSig) = userOp.signature.unpackMode();

        // If the SmartSession.USE mode was selected, no futher policies have to be enabled.
        // We can go straight to userOp validation
        // This condition is the average case, so should be handled as the first condition
        if (mode.isUseMode()) {
            // USE mode: Directly enforce policies without enabling new ones
            vd = _enforcePolicies({
                permissionId: permissionId,
                userOpHash: userOpHash,
                userOp: userOp,
                decompressedSignature: packedSig.decodeUse(),
                account: account
            });
        }
        // If the SmartSession.ENABLE mode was selected, the userOp.signature will contain the EnableSession data
        // This data will be used to enable policies and signer for the session
        // The signature of the user on the EnableSession data will be checked
        // If the signature is valid, the policies and signer will be enabled
        // after enabling the session, the policies will be enforced on the userOp similarly to the SmartSession.USE
        else if (mode.isEnableMode()) {
            // _enablePolicies slices out the data required to enable a session from userOp.signature and returns the
            // data required to use the actual session
            // ENABLE mode: Enable new policies and then enforce them
            bytes memory usePermissionSig =
                _enablePolicies({ permissionId: permissionId, packedSig: packedSig, account: account, mode: mode });

            vd = _enforcePolicies({
                permissionId: permissionId,
                userOpHash: userOpHash,
                userOp: userOp,
                decompressedSignature: usePermissionSig,
                account: account
            });
        }
        // if an Unknown mode is provided, the function will revert
        else {
            revert UnsupportedSmartSessionMode(mode);
        }
    }

    /**
     * @notice Enables policies for a session during user operation validation
     * @dev This function handles the enabling of new policies and session validators
     * @param permissionId The unique identifier for the permission set
     * @param packedSig Packed signature data containing enable information
     * @param account The account for which policies are being enabled
     * @param mode The SmartSession mode being used
     * @return permissionUseSig The signature to be used for the actual session
     */
    function _enablePolicies(
        PermissionId permissionId,
        bytes calldata packedSig,
        address account,
        SmartSessionMode mode
    )
        internal
        returns (bytes memory permissionUseSig)
    {
        // Decode the enable data from the packed signature
        EnableSession memory enableData;
        (enableData, permissionUseSig) = packedSig.decodeEnable();

        // Increment nonce to prevent replay attacks
        uint256 nonce = $signerNonce[permissionId][account]++;
        bytes32 hash = enableData.getAndVerifyDigest(account, nonce, mode);

        // Verify that the provided permissionId matches the computed one
        if (permissionId != enableData.sessionToEnable.toPermissionIdMemory()) {
            revert InvalidPermissionId(permissionId);
        }

        // require signature on account
        // this is critical as it is the only way to ensure that the user is aware of the policies and signer
        // NOTE: although SmartSession implements a ERC1271 feature, it CAN NOT be used as a valid ERC1271 validator for
        // this step. SmartSessions ERC1271 function must prevent this
        if (IERC1271(account).isValidSignature(hash, enableData.permissionEnableSig) != EIP1271_MAGIC_VALUE) {
            revert InvalidEnableSignature(account, hash);
        }

        // enable ISessionValidator for this session
        // if we do not have to enable ISessionValidator, we just add policies
        // Attention: policies to add should be all new.
        if (!_isISessionValidatorSet(permissionId, account) && mode.enableSigner()) {
            _enableISessionValidator(
                permissionId,
                account,
                enableData.sessionToEnable.sessionValidator,
                enableData.sessionToEnable.sessionValidatorInitData
            );
        }

        // Determine if registry should be used based on the mode
        bool useRegistry = mode.useRegistry();

        // Enable UserOp policies
        $userOpPolicies.enable({
            policyType: PolicyType.USER_OP,
            permissionId: permissionId,
            configId: permissionId.toUserOpPolicyId().toConfigId(),
            policyDatas: enableData.sessionToEnable.userOpPolicies,
            smartAccount: account,
            useRegistry: useRegistry
        });

        // Enable ERC1271 policies
        $erc1271Policies.enable({
            policyType: PolicyType.ERC1271,
            permissionId: permissionId,
            configId: permissionId.toErc1271PolicyId().toConfigId(),
            policyDatas: enableData.sessionToEnable.erc7739Policies.erc1271Policies,
            smartAccount: account,
            useRegistry: useRegistry
        });

        // Enable action policies
        $actionPolicies.enable({
            permissionId: permissionId,
            actionPolicyDatas: enableData.sessionToEnable.actions,
            smartAccount: account,
            useRegistry: useRegistry
        });

        // Mark the session as enabled
        $enabledSessions.add(msg.sender, PermissionId.unwrap(permissionId));
    }

    /**
     * @notice Enforces policies and checks ISessionValidator signature for a session
     * @dev This function is the core of policy enforcement in SmartSession
     * @param permissionId The unique identifier for the permission set
     * @param userOpHash The hash of the user operation
     * @param userOp The user operation being validated
     * @param decompressedSignature The decompressed signature for validation
     * @param account The account for which policies are being enforced
     * @return vd ValidationData containing the result of policy checks
     */
    function _enforcePolicies(
        PermissionId permissionId,
        bytes32 userOpHash,
        PackedUserOperation calldata userOp,
        bytes memory decompressedSignature,
        address account
    )
        internal
        returns (ValidationData vd)
    {
        // ensure that the permissionId is enabled
        if (!$enabledSessions.contains({ account: account, value: PermissionId.unwrap(permissionId) })) {
            revert InvalidPermissionId(permissionId);
        }
        /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
        /*                 Check SessionKey ISessionValidator         */
        /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

        // Validate the session key signature
        // this call reverts if the ISessionValidator is not set or signature is invalid
        $sessionValidators.requireValidISessionValidator({
            userOpHash: userOpHash,
            account: account,
            permissionId: permissionId,
            signature: decompressedSignature
        });

        /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
        /*                    Check UserOp Policies                   */
        /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
        // Check UserOp policies
        // This reverts if policies are violated
        vd = $userOpPolicies.check({
            userOp: userOp,
            permissionId: permissionId,
            callOnIPolicy: abi.encodeCall(IUserOpPolicy.checkUserOpPolicy, (permissionId.toConfigId(), userOp)),
            minPolicies: 0 // for userOp policies, a min of 0 is ok. since these are not security critical
         });

        bytes4 selector = bytes4(userOp.callData[0:4]);

        /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
        /*                      Handle Executions                     */
        /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
        // if the selector indicates that the userOp is an execution,
        // action policies have to be checked
        if (selector == IERC7579Account.execute.selector) {
            // Decode ERC7579 execution mode
            ExecutionMode mode = ExecutionMode.wrap(bytes32(userOp.callData[4:36]));
            CallType callType;
            ExecType execType;

            // solhint-disable-next-line no-inline-assembly
            assembly {
                callType := mode
                execType := shl(8, mode)
            }
            if (ExecType.unwrap(execType) != ExecType.unwrap(EXECTYPE_DEFAULT)) {
                revert UnsupportedExecutionType();
            }
            // DEFAULT EXEC & BATCH CALL
            else if (callType == CALLTYPE_BATCH) {
                vd = $actionPolicies.actionPolicies.checkBatch7579Exec({
                    userOp: userOp,
                    permissionId: permissionId,
                    minPolicies: 1 // minimum of one actionPolicy must be set.
                 });
            }
            // DEFAULT EXEC & SINGLE CALL
            else if (callType == CALLTYPE_SINGLE) {
                (address target, uint256 value, bytes calldata callData) =
                    userOp.callData.decodeUserOpCallData().decodeSingle();
                vd = $actionPolicies.actionPolicies.checkSingle7579Exec({
                    userOp: userOp,
                    permissionId: permissionId,
                    target: target,
                    value: value,
                    callData: callData,
                    minPolicies: 1 // minimum of one actionPolicy must be set.
                 });
            } else {
                revert UnsupportedExecutionType();
            }
        }
        // SmartSession does not support executeUserOp,
        // should this function selector be used in the userOp: revert
        // see why: https://github.com/erc7579/smartsessions/issues/17
        else if (selector == IAccountExecute.executeUserOp.selector) {
            revert UnsupportedExecutionType();
        }
        /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
        /*                        Handle Actions                      */
        /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
        // all other executions are supported and are handled by the actionPolicies
        else {
            ActionId actionId = account.toActionId(bytes4(userOp.callData[:4]));

            vd = $actionPolicies.actionPolicies[actionId].check({
                userOp: userOp,
                permissionId: permissionId,
                callOnIPolicy: abi.encodeCall(
                    IActionPolicy.checkAction,
                    (
                        permissionId.toConfigId(actionId),
                        account, // account
                        account, // target
                        0, // value
                        userOp.callData // data
                    )
                ),
                minPolicies: 1
            });
        }
    }

    function isValidSignatureWithSender(
        address sender,
        bytes32 hash,
        bytes calldata signature
    )
        external
        view
        override
        returns (bytes4 result)
    {
        // disallow that session can be authorized by other sessions
        if (sender == address(this)) return 0xffffffff;

        bool success = _erc1271IsValidSignatureViaNestedEIP712(sender, hash, _erc1271UnwrapSignature(signature));
        /// @solidity memory-safe-assembly
        assembly {
            // `success ? bytes4(keccak256("isValidSignature(bytes32,bytes)")) : 0xffffffff`.
            // We use `0xffffffff` for invalid, in convention with the reference implementation.
            result := shl(224, or(0x1626ba7e, sub(0, iszero(success))))
        }
    }

    function _erc1271IsValidSignatureNowCalldata(
        address sender,
        bytes32 hash,
        bytes calldata signature,
        bytes calldata contents
    )
        internal
        view
        virtual
        override
        returns (bool valid)
    {
        bytes32 contentHash = string(contents).hashERC7739Content();
        PermissionId permissionId = PermissionId.wrap(bytes32(signature[0:32]));
        signature = signature[32:];
        ConfigId configId = permissionId.toErc1271PolicyId().toConfigId(msg.sender);
        if (!$enabledERC7739Content[configId][contentHash][msg.sender]) return false;
        valid = $erc1271Policies.checkERC1271({
            account: msg.sender,
            requestSender: sender,
            hash: hash,
            signature: signature,
            permissionId: permissionId,
            configId: configId,
            minPoliciesToEnforce: 0
        });

        if (!valid) return false;
        // this call reverts if the ISessionValidator is not set or signature is invalid
        return $sessionValidators.isValidISessionValidator({
            hash: hash,
            account: msg.sender,
            permissionId: permissionId,
            signature: signature
        });
    }
}
