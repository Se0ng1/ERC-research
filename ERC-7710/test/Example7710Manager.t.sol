// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";

import {Example7710Manager} from "../src/Example7710Manager.sol";
import {MockERC7579Account} from "../src/MockERC7579Account.sol";
import {MockSwapTarget} from "../src/MockSwapTarget.sol";

contract Example7710ManagerTest is Test {
    Example7710Manager internal manager;
    MockERC7579Account internal account;
    ExampleTarget internal target;
    ExampleClaimTarget internal claimTarget;
    MockSwapTarget internal swapTarget;

    uint256 internal constant ADMIN_KEY = 0xA11CE;
    uint256 internal constant INVALID_SIGNER_KEY = 0xB0B;
    uint256 internal constant OPERATOR_KEY = 0xCAFE;
    uint256 internal constant MODULE_TYPE_EXECUTOR = 2;
    bytes32 internal constant SAMPLE_MODE = bytes32(uint256(1));
    bytes32 internal constant UNSUPPORTED_MODE = bytes32(uint256(2));
    bytes32 internal constant UNKNOWN_PERMISSION_TYPE = keccak256("unknown");
    bytes32 internal constant DELEGATION_TYPEHASH = keccak256(
        "Delegation(address delegator,address operator,bytes32 permissionType,address target,bytes4 selector,bytes32 authority)"
    );
    address internal constant TOKEN_IN = address(0x1111);
    address internal constant TOKEN_OUT = address(0x2222);
    address internal admin;
    address internal operator;
    bytes32 internal domainSeparator;

    function setUp() public {
        admin = vm.addr(ADMIN_KEY);
        operator = vm.addr(OPERATOR_KEY);

        manager = new Example7710Manager();
        domainSeparator = manager.domainSeparator();
        account = new MockERC7579Account(admin);
        vm.prank(admin);
        account.installModule(MODULE_TYPE_EXECUTOR, address(manager), "");
        vm.prank(admin);
        account.installExecutionMode(SAMPLE_MODE);
        target = new ExampleTarget();
        claimTarget = new ExampleClaimTarget();
        swapTarget = new MockSwapTarget();
    }

    function testDemoFrontendDrivenSwapFlow() public {
        // 프론트가 새 account, manager, swap target 주소를 준비했다고 가정한다.
        Example7710Manager demoManager = new Example7710Manager();
        MockERC7579Account demoAccount = new MockERC7579Account(admin);
        MockSwapTarget demoSwapTarget = new MockSwapTarget();
        bytes32 demoDomainSeparator = demoManager.domainSeparator();

        // 1. 프론트가 admin 지갑에 ERC-7710 Manager를 executor module로 설치하는 트랜잭션을 요청한다.
        vm.prank(admin);
        demoAccount.installModule(MODULE_TYPE_EXECUTOR, address(demoManager), "");

        assertTrue(
            demoAccount.isModuleInstalled(MODULE_TYPE_EXECUTOR, address(demoManager), ""),
            "manager module should be installed"
        );
        assertTrue(demoAccount.isExecutor(address(demoManager)), "manager should be executor");

        // 2. 프론트가 admin 지갑에 swap에서 사용할 mode를 활성화하는 트랜잭션을 요청한다.
        vm.prank(admin);
        demoAccount.installExecutionMode(SAMPLE_MODE);

        assertTrue(demoAccount.supportsExecutionMode(SAMPLE_MODE), "swap mode should be supported");

        // 3. 프론트가 admin 지갑에 operator에게 줄 swap permission delegation 서명을 요청한다.
        Example7710Manager.Delegation memory delegation = Example7710Manager.Delegation({
            delegator: address(demoAccount),
            operator: operator,
            permissionType: demoManager.PERMISSION_TYPE_SWAP(),
            target: address(demoSwapTarget),
            selector: MockSwapTarget.swapExactInput.selector,
            authority: demoManager.ROOT_AUTHORITY(),
            signature: ""
        });
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
        bytes32 delegationHash = keccak256(abi.encodePacked("\x19\x01", demoDomainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ADMIN_KEY, delegationHash);
        delegation.signature = abi.encodePacked(r, s, v);

        // 4. operator 프론트가 permission context, mode, swap calldata를 묶어 Manager에 redeem을 요청한다.
        bytes[] memory permissionContexts = new bytes[](1);
        permissionContexts[0] = abi.encode(delegation);

        bytes32[] memory modes = new bytes32[](1);
        modes[0] = SAMPLE_MODE;

        bytes memory swapCallData =
            abi.encodeCall(MockSwapTarget.swapExactInput, (TOKEN_IN, TOKEN_OUT, uint256(100), uint256(200), operator));

        bytes[] memory executionCallDatas = new bytes[](1);
        executionCallDatas[0] = abi.encode(address(demoSwapTarget), uint256(0), swapCallData);

        vm.prank(operator);
        demoManager.redeemDelegations(permissionContexts, modes, executionCallDatas);

        assertEq(demoAccount.lastExecutor(), address(demoManager), "manager should execute through account");
        assertEq(demoAccount.lastMode(), SAMPLE_MODE, "mode should be forwarded");
        assertEq(demoSwapTarget.lastCaller(), address(demoAccount), "account should call swap target");
        assertEq(demoSwapTarget.lastRecipient(), operator, "operator should receive swap credit");
        assertEq(demoSwapTarget.creditedAmount(operator, TOKEN_OUT), 200, "swap output should be credited");
    }

    function testRedeemExecutesClaimThroughAccount() public {
        // admin이 account의 ERC-1271 서명을 통해 operator에게 claim 권한만 위임한다.
        Example7710Manager.Delegation memory delegation = Example7710Manager.Delegation({
            delegator: address(account),
            operator: operator,
            permissionType: manager.PERMISSION_TYPE_CLAIM(),
            target: address(claimTarget),
            selector: ExampleClaimTarget.claim.selector,
            authority: manager.ROOT_AUTHORITY(),
            signature: ""
        });
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
        bytes32 delegationHash = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ADMIN_KEY, delegationHash);
        delegation.signature = abi.encodePacked(r, s, v);

        // 매니저는 permission context, mode, 실행 calldata를 같은 index로 묶어 처리한다.
        bytes[] memory permissionContexts = new bytes[](1);
        permissionContexts[0] = abi.encode(delegation);

        bytes32[] memory modes = new bytes32[](1);
        modes[0] = SAMPLE_MODE;

        bytes[] memory executionCallDatas = new bytes[](1);
        executionCallDatas[0] =
            abi.encode(address(claimTarget), uint256(0), abi.encodeCall(ExampleClaimTarget.claim, (operator)));

        // operator가 위임을 redeem하면 실제 claim 호출은 account를 통해 실행된다.
        vm.prank(operator);
        manager.redeemDelegations(permissionContexts, modes, executionCallDatas);

        assertEq(claimTarget.claimCount(), 1, "claim should be executed");
        assertEq(claimTarget.lastCaller(), address(account), "account should call claim target");
        assertEq(claimTarget.lastRecipient(), operator, "operator should receive claim");
        assertEq(account.lastExecutor(), address(manager), "manager should execute via account");
        assertEq(account.lastMode(), SAMPLE_MODE, "mode should be forwarded");
    }

    function testRedeemExecutesSwapThroughAccount() public {
        // admin이 operator에게 swap 권한만 위임한다.
        Example7710Manager.Delegation memory delegation = Example7710Manager.Delegation({
            delegator: address(account),
            operator: operator,
            permissionType: manager.PERMISSION_TYPE_SWAP(),
            target: address(swapTarget),
            selector: MockSwapTarget.swapExactInput.selector,
            authority: manager.ROOT_AUTHORITY(),
            signature: ""
        });
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
        bytes32 delegationHash = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ADMIN_KEY, delegationHash);
        delegation.signature = abi.encodePacked(r, s, v);

        bytes[] memory permissionContexts = new bytes[](1);
        permissionContexts[0] = abi.encode(delegation);

        bytes32[] memory modes = new bytes32[](1);
        modes[0] = SAMPLE_MODE;

        bytes memory swapCallData =
            abi.encodeCall(MockSwapTarget.swapExactInput, (TOKEN_IN, TOKEN_OUT, uint256(100), uint256(200), operator));

        bytes[] memory executionCallDatas = new bytes[](1);
        executionCallDatas[0] = abi.encode(address(swapTarget), uint256(0), swapCallData);

        vm.prank(operator);
        manager.redeemDelegations(permissionContexts, modes, executionCallDatas);

        assertEq(swapTarget.lastCaller(), address(account), "account should call swap target");
        assertEq(swapTarget.lastRecipient(), operator, "operator should receive swap credit");
        assertEq(swapTarget.lastTokenIn(), TOKEN_IN, "token in should be recorded");
        assertEq(swapTarget.lastTokenOut(), TOKEN_OUT, "token out should be recorded");
        assertEq(swapTarget.lastAmountIn(), 100, "amount in should be recorded");
        assertEq(swapTarget.lastAmountOut(), 200, "amount out should use mock rate");
        assertEq(swapTarget.creditedAmount(operator, TOKEN_OUT), 200, "output credit should be recorded");
    }

    function testRevertTupleLengthMismatch() public {
        // 세 배열은 tuple처럼 같은 길이여야 한다.
        bytes[] memory permissionContexts = new bytes[](1);
        bytes32[] memory modes = new bytes32[](0);
        bytes[] memory executionCallDatas = new bytes[](1);

        vm.expectRevert(Example7710Manager.TupleDataLengthMismatch.selector);
        manager.redeemDelegations(permissionContexts, modes, executionCallDatas);
    }

    function testMockAccountRejectsUnknownExecutor() public {
        bytes memory executionCallData =
            abi.encode(address(target), uint256(0), abi.encodeCall(ExampleTarget.setNumber, (1)));

        vm.expectRevert(MockERC7579Account.UnauthorizedExecutor.selector);
        account.executeFromExecutor(SAMPLE_MODE, executionCallData);
    }

    function testMockAccountRejectsUnsupportedMode() public {
        bytes memory executionCallData =
            abi.encode(address(target), uint256(0), abi.encodeCall(ExampleTarget.setNumber, (1)));

        vm.expectRevert(abi.encodeWithSelector(MockERC7579Account.UnsupportedExecutionMode.selector, UNSUPPORTED_MODE));
        vm.prank(address(manager));
        account.executeFromExecutor(UNSUPPORTED_MODE, executionCallData);
    }

    function testMockAccountRejectsDuplicateModuleInstall() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                MockERC7579Account.ModuleAlreadyInstalled.selector, MODULE_TYPE_EXECUTOR, address(manager)
            )
        );
        vm.prank(admin);
        account.installModule(MODULE_TYPE_EXECUTOR, address(manager), "");
    }

    function testMockAccountRejectsUnsupportedModuleType() public {
        uint256 hookModuleType = account.MODULE_TYPE_HOOK();

        vm.expectRevert(abi.encodeWithSelector(MockERC7579Account.UnsupportedModuleType.selector, hookModuleType));
        vm.prank(admin);
        account.installModule(hookModuleType, address(manager), "");
    }

    function testMockAccountUninstallModuleRevokesExecutor() public {
        vm.prank(admin);
        account.uninstallModule(MODULE_TYPE_EXECUTOR, address(manager), "");

        assertFalse(account.isModuleInstalled(MODULE_TYPE_EXECUTOR, address(manager), ""), "module should be removed");
        assertFalse(account.isExecutor(address(manager)), "executor should be revoked");

        bytes memory executionCallData =
            abi.encode(address(target), uint256(0), abi.encodeCall(ExampleTarget.setNumber, (1)));

        vm.expectRevert(MockERC7579Account.UnauthorizedExecutor.selector);
        vm.prank(address(manager));
        account.executeFromExecutor(SAMPLE_MODE, executionCallData);
    }

    function testRevertSwapPermissionCannotCallClaimTarget() public {
        // swap 권한은 claim target 호출에 사용할 수 없다.
        Example7710Manager.Delegation memory delegation = Example7710Manager.Delegation({
            delegator: address(account),
            operator: operator,
            permissionType: manager.PERMISSION_TYPE_SWAP(),
            target: address(swapTarget),
            selector: MockSwapTarget.swapExactInput.selector,
            authority: manager.ROOT_AUTHORITY(),
            signature: ""
        });
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
        bytes32 delegationHash = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ADMIN_KEY, delegationHash);
        delegation.signature = abi.encodePacked(r, s, v);

        bytes[] memory permissionContexts = new bytes[](1);
        permissionContexts[0] = abi.encode(delegation);

        bytes32[] memory modes = new bytes32[](1);
        modes[0] = SAMPLE_MODE;

        bytes[] memory executionCallDatas = new bytes[](1);
        executionCallDatas[0] =
            abi.encode(address(claimTarget), uint256(0), abi.encodeCall(ExampleClaimTarget.claim, (operator)));

        vm.expectRevert(
            abi.encodeWithSelector(
                Example7710Manager.InvalidPermissionTarget.selector, address(swapTarget), address(claimTarget)
            )
        );
        vm.prank(operator);
        manager.redeemDelegations(permissionContexts, modes, executionCallDatas);
    }

    function testRevertSwapPermissionCannotCallWrongSelector() public {
        // swap target이 맞아도 허용된 selector가 아니면 실행할 수 없다.
        Example7710Manager.Delegation memory delegation = Example7710Manager.Delegation({
            delegator: address(account),
            operator: operator,
            permissionType: manager.PERMISSION_TYPE_SWAP(),
            target: address(swapTarget),
            selector: MockSwapTarget.swapExactInput.selector,
            authority: manager.ROOT_AUTHORITY(),
            signature: ""
        });
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
        bytes32 delegationHash = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ADMIN_KEY, delegationHash);
        delegation.signature = abi.encodePacked(r, s, v);

        bytes[] memory permissionContexts = new bytes[](1);
        permissionContexts[0] = abi.encode(delegation);

        bytes32[] memory modes = new bytes32[](1);
        modes[0] = SAMPLE_MODE;

        bytes4 wrongSelector = bytes4(0x12345678);
        bytes[] memory executionCallDatas = new bytes[](1);
        executionCallDatas[0] = abi.encode(address(swapTarget), uint256(0), abi.encodeWithSelector(wrongSelector));

        vm.expectRevert(
            abi.encodeWithSelector(
                Example7710Manager.InvalidPermissionSelector.selector,
                MockSwapTarget.swapExactInput.selector,
                wrongSelector
            )
        );
        vm.prank(operator);
        manager.redeemDelegations(permissionContexts, modes, executionCallDatas);
    }

    function testRevertUnsupportedPermissionType() public {
        Example7710Manager.Delegation memory delegation = Example7710Manager.Delegation({
            delegator: address(account),
            operator: operator,
            permissionType: UNKNOWN_PERMISSION_TYPE,
            target: address(claimTarget),
            selector: ExampleClaimTarget.claim.selector,
            authority: manager.ROOT_AUTHORITY(),
            signature: ""
        });
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
        bytes32 delegationHash = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ADMIN_KEY, delegationHash);
        delegation.signature = abi.encodePacked(r, s, v);

        bytes[] memory permissionContexts = new bytes[](1);
        permissionContexts[0] = abi.encode(delegation);

        bytes32[] memory modes = new bytes32[](1);
        modes[0] = SAMPLE_MODE;

        bytes[] memory executionCallDatas = new bytes[](1);
        executionCallDatas[0] =
            abi.encode(address(claimTarget), uint256(0), abi.encodeCall(ExampleClaimTarget.claim, (operator)));

        vm.expectRevert(
            abi.encodeWithSelector(Example7710Manager.UnsupportedPermissionType.selector, UNKNOWN_PERMISSION_TYPE)
        );
        vm.prank(operator);
        manager.redeemDelegations(permissionContexts, modes, executionCallDatas);
    }

    function testRevertInvalidSignature() public {
        // account는 ERC-1271로 admin의 서명을 검증한다.
        Example7710Manager.Delegation memory delegation = Example7710Manager.Delegation({
            delegator: address(account),
            operator: operator,
            permissionType: manager.PERMISSION_TYPE_CLAIM(),
            target: address(claimTarget),
            selector: ExampleClaimTarget.claim.selector,
            authority: manager.ROOT_AUTHORITY(),
            signature: ""
        });
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
        bytes32 delegationHash = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(INVALID_SIGNER_KEY, delegationHash);
        delegation.signature = abi.encodePacked(r, s, v);

        bytes[] memory permissionContexts = new bytes[](1);
        permissionContexts[0] = abi.encode(delegation);

        bytes32[] memory modes = new bytes32[](1);
        modes[0] = SAMPLE_MODE;

        bytes[] memory executionCallDatas = new bytes[](1);
        executionCallDatas[0] =
            abi.encode(address(claimTarget), uint256(0), abi.encodeCall(ExampleClaimTarget.claim, (operator)));

        // admin이 아닌 주소의 서명은 ERC-1271 검증에서 거부된다.
        vm.expectRevert(Example7710Manager.InvalidSignature.selector);
        vm.prank(operator);
        manager.redeemDelegations(permissionContexts, modes, executionCallDatas);
    }

    function testRevertCallerNotOperator() public {
        // 유효한 위임을 만들되, 호출자를 operator가 아닌 주소로 바꿔 실패를 검증한다.
        Example7710Manager.Delegation memory delegation = Example7710Manager.Delegation({
            delegator: address(account),
            operator: operator,
            permissionType: manager.PERMISSION_TYPE_CLAIM(),
            target: address(claimTarget),
            selector: ExampleClaimTarget.claim.selector,
            authority: manager.ROOT_AUTHORITY(),
            signature: ""
        });
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
        bytes32 delegationHash = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ADMIN_KEY, delegationHash);
        delegation.signature = abi.encodePacked(r, s, v);

        bytes[] memory permissionContexts = new bytes[](1);
        permissionContexts[0] = abi.encode(delegation);

        bytes32[] memory modes = new bytes32[](1);
        modes[0] = SAMPLE_MODE;

        bytes[] memory executionCallDatas = new bytes[](1);
        executionCallDatas[0] =
            abi.encode(address(claimTarget), uint256(0), abi.encodeCall(ExampleClaimTarget.claim, (operator)));

        // msg.sender가 delegation.operator가 아니면 redeem할 수 없다.
        vm.expectRevert(Example7710Manager.InvalidOperator.selector);
        vm.prank(address(0xBAD));
        manager.redeemDelegations(permissionContexts, modes, executionCallDatas);
    }

    function testRevertInvalidAuthority() public {
        // 단일 delegation은 root authority에서 직접 시작해야 한다.
        Example7710Manager.Delegation memory delegation = Example7710Manager.Delegation({
            delegator: address(account),
            operator: operator,
            permissionType: manager.PERMISSION_TYPE_CLAIM(),
            target: address(claimTarget),
            selector: ExampleClaimTarget.claim.selector,
            authority: bytes32(uint256(0xDEAD)),
            signature: ""
        });
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
        bytes32 delegationHash = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ADMIN_KEY, delegationHash);
        delegation.signature = abi.encodePacked(r, s, v);

        bytes[] memory permissionContexts = new bytes[](1);
        permissionContexts[0] = abi.encode(delegation);

        bytes32[] memory modes = new bytes32[](1);
        modes[0] = SAMPLE_MODE;

        bytes[] memory executionCallDatas = new bytes[](1);
        executionCallDatas[0] =
            abi.encode(address(claimTarget), uint256(0), abi.encodeCall(ExampleClaimTarget.claim, (operator)));

        // root authority가 아니므로 delegation 검증 단계에서 실패한다.
        vm.expectRevert(Example7710Manager.InvalidAuthority.selector);
        vm.prank(operator);
        manager.redeemDelegations(permissionContexts, modes, executionCallDatas);
    }
}

contract ExampleTarget {
    uint256 public number;
    address public lastCaller;

    // account를 통해 호출되었는지 확인하기 위한 단순 target 함수.
    function setNumber(uint256 newNumber) external {
        number = newNumber;
        lastCaller = msg.sender;
    }
}

contract ExampleClaimTarget {
    uint256 public claimCount;
    address public lastCaller;
    address public lastRecipient;

    // account를 통해 claim 기능이 호출되었는지 확인하기 위한 단순 target 함수.
    function claim(address recipient) external {
        claimCount++;
        lastCaller = msg.sender;
        lastRecipient = recipient;
    }
}
