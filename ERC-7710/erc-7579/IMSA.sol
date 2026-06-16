// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @notice Minimal ERC-7579 smart account execution surface used by Example7710Manager.
/// @dev The full ERC-7579 spec defines richer mode/execution encoding. This repository only
/// needs the executor entrypoint that ERC-7710 managers call after validating delegation authority.
interface IERC7579Account {
    function executeFromExecutor(bytes32 mode, bytes calldata executionCallData)
        external
        payable
        returns (bytes[] memory returnData);
}

/// @notice ERC-7579 account configuration surface used by the mock account.
interface IERC7579AccountConfig {
    function accountId() external view returns (string memory accountImplementationId);
    function supportsExecutionMode(bytes32 encodedMode) external view returns (bool);
    function supportsModule(uint256 moduleTypeId) external view returns (bool);
}

/// @notice ERC-7579 module installation surface used by frontends or wallet SDKs.
interface IERC7579ModuleConfig {
    event ModuleInstalled(uint256 moduleTypeId, address module);
    event ModuleUninstalled(uint256 moduleTypeId, address module);

    function installModule(uint256 moduleTypeId, address module, bytes calldata initData) external;
    function uninstallModule(uint256 moduleTypeId, address module, bytes calldata deInitData) external;
    function isModuleInstalled(uint256 moduleTypeId, address module, bytes calldata additionalContext)
        external
        view
        returns (bool);
}

/// @notice Minimal ERC-7579 module interface.
interface IERC7579Module {
    function onInstall(bytes calldata data) external;
    function onUninstall(bytes calldata data) external;
    function isModuleType(uint256 moduleTypeId) external view returns (bool);
}
