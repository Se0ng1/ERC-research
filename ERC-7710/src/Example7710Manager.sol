// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC7579Account, IERC7579Module} from "../erc-7579/IMSA.sol";
import {IERC1271} from "./interfaces/IERC1271.sol";

/**
 * @title Example7710Manager
 * @notice 프로덕션 사용 목적이 아닌, delegation redemption에 초점을 둔 ERC-7710 최소 참조 구현입니다.
 * @dev 핵심 개념을 보여주기 위해 의도적으로 단순화한 구현입니다.
 * 조건부 권한 검증과 revocation 같은 기능을 포함한 완전한 프로덕션 구현은 MetaMask Delegation Framework를 참고하세요:
 * https://github.com/MetaMask/delegation-framework/blob/main/src/DelegationManager.sol
 */
contract Example7710Manager is IERC7579Module {
    ////////////////////////////// 타입 //////////////////////////////

    struct Delegation {
        address delegator; // 권한을 위임하는 주소
        address operator; // 권한을 받아 실행하는 주소
        bytes32 permissionType; // swap, token-transfer, claim 같은 표준화된 권한 타입
        address target; // 이 권한으로 호출할 수 있는 target
        bytes4 selector; // 이 권한으로 호출할 수 있는 function selector
        bytes32 authority; // 위임되는 권한 또는 ROOT_AUTHORITY
        bytes signature; // 이 위임을 승인한 delegator의 서명
    }

    ////////////////////////////// 에러 //////////////////////////////

    error TupleDataLengthMismatch();
    error InvalidOperator();
    error InvalidAuthority();
    error InvalidSignature();
    error UnsupportedPermissionType(bytes32 permissionType);
    error InvalidPermissionTarget(address expected, address actual);
    error InvalidPermissionSelector(bytes4 expected, bytes4 actual);

    ////////////////////////////// 상수 //////////////////////////////

    /// @dev delegator가 root authority임을 나타내는 특수 authority 값
    bytes32 public constant ROOT_AUTHORITY = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
    uint256 public constant MODULE_TYPE_EXECUTOR = 2;
    bytes32 public constant PERMISSION_TYPE_SWAP = keccak256("swap");
    bytes32 public constant PERMISSION_TYPE_TOKEN_TRANSFER = keccak256("token-transfer");
    bytes32 public constant PERMISSION_TYPE_CLAIM = keccak256("claim");
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant NAME_HASH = keccak256("Example7710Manager");
    bytes32 internal constant VERSION_HASH = keccak256("1");
    bytes32 internal constant DELEGATION_TYPEHASH =
        keccak256(
            "Delegation(address delegator,address operator,bytes32 permissionType,address target,bytes4 selector,bytes32 authority)"
        );
    bytes4 internal constant ERC1271_MAGICVALUE = 0x1626ba7e;
    uint256 internal constant SECP256K1_N_DIV_2 = 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;

    ////////////////////////////// 외부 함수 //////////////////////////////

    /**
     * @notice delegation 권한을 검증한 뒤 위임된 동작을 실행합니다.
     * @param _permissionContexts 각 항목은 Account -> Operator 단일 Delegation을 ABI 인코딩한 값입니다.
     * @param _modes 각 동작의 실행 mode입니다(ERC-7579 참고).
     * @param _executionCallDatas 실행할 동작을 인코딩한 calldata입니다.
     */
    function redeemDelegations(
        bytes[] calldata _permissionContexts,
        bytes32[] calldata _modes,
        bytes[] calldata _executionCallDatas
    ) external {
        uint256 batchSize_ = _permissionContexts.length;
        if (batchSize_ != _executionCallDatas.length || batchSize_ != _modes.length) {
            revert TupleDataLengthMismatch();
        }

        // 각 batch를 처리한다.
        for (uint256 batchIndex_; batchIndex_ < batchSize_; ++batchIndex_) {
            Delegation memory delegation_ = abi.decode(_permissionContexts[batchIndex_], (Delegation));

            // 호출자가 delegation의 operator인지 확인한다.
            if (delegation_.operator != msg.sender) {
                revert InvalidOperator();
            }

            bytes32 delegationHash_ = _getDelegationHash(delegation_);

            // EOA delegator는 ECDSA로, contract delegator는 ERC-1271로 서명을 검증한다.
            if (!_isValidSignature(delegationHash_, delegation_.signature, delegation_.delegator)) {
                revert InvalidSignature();
            }

            // 단일 delegation은 ROOT_AUTHORITY에서 직접 시작해야 한다.
            if (delegation_.authority != ROOT_AUTHORITY) {
                revert InvalidAuthority();
            }

            _validatePermissionCall(delegation_, _executionCallDatas[batchIndex_]);

            // delegator account에서 위임된 동작을 실행한다.
            IERC7579Account(delegation_.delegator).executeFromExecutor(
                _modes[batchIndex_], _executionCallDatas[batchIndex_]
            );
        }
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparator();
    }

    /**
     * @notice ERC-7579 account가 executor module 설치 시 호출하는 hook입니다.
     * @dev 예제 manager는 별도 설치 상태가 없으므로 hook을 no-op으로 둡니다.
     */
    function onInstall(bytes calldata) external pure {}

    /**
     * @notice ERC-7579 account가 executor module 제거 시 호출하는 hook입니다.
     * @dev 예제 manager는 별도 제거 상태가 없으므로 hook을 no-op으로 둡니다.
     */
    function onUninstall(bytes calldata) external pure {}

    /**
     * @notice 이 manager가 ERC-7579 executor module 타입인지 확인합니다.
     */
    function isModuleType(uint256 moduleTypeId) external pure returns (bool) {
        return moduleTypeId == MODULE_TYPE_EXECUTOR;
    }

    ////////////////////////////// 내부 함수 //////////////////////////////

    /**
     * @notice Delegation struct의 EIP-712 typed data digest를 생성합니다.
     * @dev signature 필드는 서명 대상에서 제외하고, 위임 범위 필드만 typed struct로 묶습니다.
     */
    function _getDelegationHash(Delegation memory delegation) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                DELEGATION_TYPEHASH,
                delegation.delegator,
                delegation.operator,
                delegation.permissionType,
                delegation.target,
                delegation.selector,
                delegation.authority
            )
        );

        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    /**
     * @notice EOA 서명은 ECDSA로, contract 서명은 ERC-1271로 검증합니다.
     * @dev EIP-712 digest에 대한 서명을 검증합니다.
     */
    function _isValidSignature(bytes32 hash, bytes memory signature, address signer) internal view returns (bool) {
        if (signer.code.length > 0) {
            (bool success, bytes memory result) =
                signer.staticcall(abi.encodeCall(IERC1271.isValidSignature, (hash, signature)));
            return success && result.length >= 32 && bytes4(result) == ERC1271_MAGICVALUE;
        }

        if (signature.length != 65) {
            return false;
        }

        bytes32 r;
        bytes32 s;
        uint8 v;

        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }

        if (uint256(s) > SECP256K1_N_DIV_2) {
            return false;
        }

        if (v != 27 && v != 28) {
            return false;
        }

        return ecrecover(hash, v, r, s) == signer;
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)));
    }

    function _validatePermissionCall(Delegation memory delegation, bytes memory executionCallData) internal pure {
        if (!_isSupportedPermissionType(delegation.permissionType)) {
            revert UnsupportedPermissionType(delegation.permissionType);
        }

        (address target,, bytes memory callData) = abi.decode(executionCallData, (address, uint256, bytes));
        if (target != delegation.target) {
            revert InvalidPermissionTarget(delegation.target, target);
        }

        bytes4 actualSelector = _selectorOf(callData);
        if (actualSelector != delegation.selector) {
            revert InvalidPermissionSelector(delegation.selector, actualSelector);
        }
    }

    function _isSupportedPermissionType(bytes32 permissionType) internal pure returns (bool) {
        return permissionType == PERMISSION_TYPE_SWAP || permissionType == PERMISSION_TYPE_TOKEN_TRANSFER
            || permissionType == PERMISSION_TYPE_CLAIM;
    }

    function _selectorOf(bytes memory callData) internal pure returns (bytes4 selector) {
        if (callData.length < 4) {
            return bytes4(0);
        }

        assembly {
            selector := mload(add(callData, 0x20))
        }
    }
}
