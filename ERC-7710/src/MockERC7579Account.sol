// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC7579Account, IERC7579AccountConfig, IERC7579Module, IERC7579ModuleConfig} from "../erc-7579/IMSA.sol";
import {IERC1271} from "./interfaces/IERC1271.sol";

/**
 * @title MockERC7579Account
 * @notice ERC-7710 manager 예제의 call path를 확인하기 위한 최소 ERC-7579 account mock입니다.
 * @dev MetaMask DeleGator 같은 실제 account를 붙이기 전 단계의 테스트 대역입니다.
 * admin의 module/mode 등록, executeFromExecutor, ERC-1271 서명 검증만 제공합니다.
 */
contract MockERC7579Account is IERC7579Account, IERC7579AccountConfig, IERC7579ModuleConfig, IERC1271 {
    bytes4 internal constant ERC1271_MAGICVALUE = 0x1626ba7e;
    uint256 public constant MODULE_TYPE_VALIDATOR = 1;
    uint256 public constant MODULE_TYPE_EXECUTOR = 2;
    uint256 public constant MODULE_TYPE_FALLBACK = 3;
    uint256 public constant MODULE_TYPE_HOOK = 4;

    error OnlyAdmin();
    error InvalidExecutor();
    error InvalidExecutionMode();
    error InvalidModule();
    error UnsupportedModuleType(uint256 moduleTypeId);
    error ModuleAlreadyInstalled(uint256 moduleTypeId, address module);
    error ModuleNotInstalled(uint256 moduleTypeId, address module);
    error ModuleInstallFailed();
    error ModuleUninstallFailed();
    error UnauthorizedExecutor();
    error UnsupportedExecutionMode(bytes32 mode);

    address public immutable admin;
    address public lastExecutor;
    bytes32 public lastMode;

    mapping(address executor => bool allowed) public isExecutor;
    mapping(bytes32 mode => bool supported) public supportsExecutionMode;
    mapping(uint256 moduleTypeId => mapping(address module => bool installed)) internal installedModules;

    constructor(address admin_) {
        admin = admin_;
    }

    receive() external payable {}

    function accountId() external pure returns (string memory accountImplementationId) {
        return "ercs.mock-erc7579-account.1.0.0";
    }

    function supportsModule(uint256 moduleTypeId) public pure returns (bool) {
        return moduleTypeId == MODULE_TYPE_EXECUTOR;
    }

    function installModule(uint256 moduleTypeId, address module, bytes calldata initData) external {
        if (msg.sender != admin) {
            revert OnlyAdmin();
        }

        _installModule(moduleTypeId, module, initData);
    }

    function uninstallModule(uint256 moduleTypeId, address module, bytes calldata deInitData) external {
        if (msg.sender != admin) {
            revert OnlyAdmin();
        }

        _uninstallModule(moduleTypeId, module, deInitData);
    }

    function isModuleInstalled(uint256 moduleTypeId, address module, bytes calldata)
        external
        view
        returns (bool)
    {
        return installedModules[moduleTypeId][module];
    }

    function installExecutor(address executor) external {
        if (msg.sender != admin) {
            revert OnlyAdmin();
        }

        _installModule(MODULE_TYPE_EXECUTOR, executor, "");
    }

    function uninstallExecutor(address executor) external {
        if (msg.sender != admin) {
            revert OnlyAdmin();
        }

        _uninstallModule(MODULE_TYPE_EXECUTOR, executor, "");
    }

    function installExecutionMode(bytes32 mode) external {
        if (msg.sender != admin) {
            revert OnlyAdmin();
        }
        if (mode == bytes32(0)) {
            revert InvalidExecutionMode();
        }

        supportsExecutionMode[mode] = true;
    }

    function uninstallExecutionMode(bytes32 mode) external {
        if (msg.sender != admin) {
            revert OnlyAdmin();
        }

        supportsExecutionMode[mode] = false;
    }

    // 테스트용 ERC-1271 검증: admin의 ECDSA 서명이면 magic value를 반환한다.
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4 magicValue) {
        return _recoverSigner(hash, signature) == admin ? ERC1271_MAGICVALUE : bytes4(0xffffffff);
    }

    // 테스트용 ERC-7579 실행: 허용된 executor가 넘긴 calldata를 decode해서 target을 호출한다.
    function executeFromExecutor(bytes32 mode, bytes calldata executionCallData)
        external
        payable
        returns (bytes[] memory returnData)
    {
        if (!isExecutor[msg.sender]) {
            revert UnauthorizedExecutor();
        }
        if (!supportsExecutionMode[mode]) {
            revert UnsupportedExecutionMode(mode);
        }

        (address target, uint256 value, bytes memory callData) =
            abi.decode(executionCallData, (address, uint256, bytes));

        lastExecutor = msg.sender;
        lastMode = mode;

        (bool success, bytes memory result) = target.call{value: value}(callData);
        require(success, "MOCK_EXECUTION_FAILED");

        returnData = new bytes[](1);
        returnData[0] = result;
    }

    function _installModule(uint256 moduleTypeId, address module, bytes memory initData) internal {
        if (!supportsModule(moduleTypeId)) {
            revert UnsupportedModuleType(moduleTypeId);
        }
        if (module == address(0)) {
            revert InvalidModule();
        }
        if (installedModules[moduleTypeId][module]) {
            revert ModuleAlreadyInstalled(moduleTypeId, module);
        }
        if (module.code.length == 0 || !_supportsModuleType(module, moduleTypeId)) {
            revert UnsupportedModuleType(moduleTypeId);
        }

        installedModules[moduleTypeId][module] = true;
        if (moduleTypeId == MODULE_TYPE_EXECUTOR) {
            isExecutor[module] = true;
        }

        (bool success,) = module.call(abi.encodeCall(IERC7579Module.onInstall, (initData)));
        if (!success) {
            revert ModuleInstallFailed();
        }

        emit ModuleInstalled(moduleTypeId, module);
    }

    function _uninstallModule(uint256 moduleTypeId, address module, bytes memory deInitData) internal {
        if (!installedModules[moduleTypeId][module]) {
            revert ModuleNotInstalled(moduleTypeId, module);
        }

        installedModules[moduleTypeId][module] = false;
        if (moduleTypeId == MODULE_TYPE_EXECUTOR) {
            isExecutor[module] = false;
        }

        (bool success,) = module.call(abi.encodeCall(IERC7579Module.onUninstall, (deInitData)));
        if (!success) {
            revert ModuleUninstallFailed();
        }

        emit ModuleUninstalled(moduleTypeId, module);
    }

    function _supportsModuleType(address module, uint256 moduleTypeId) internal view returns (bool) {
        (bool success, bytes memory result) =
            module.staticcall(abi.encodeCall(IERC7579Module.isModuleType, (moduleTypeId)));

        return success && result.length >= 32 && abi.decode(result, (bool));
    }

    function _recoverSigner(bytes32 hash, bytes calldata signature) internal pure returns (address) {
        if (signature.length != 65) {
            return address(0);
        }

        bytes32 r;
        bytes32 s;
        uint8 v;

        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 0x20))
            v := byte(0, calldataload(add(signature.offset, 0x40)))
        }

        if (v != 27 && v != 28) {
            return address(0);
        }

        return ecrecover(hash, v, r, s);
    }
}
