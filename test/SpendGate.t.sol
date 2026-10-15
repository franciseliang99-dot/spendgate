// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, stdError} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SpendGate, ISpendGate} from "../src/SpendGate.sol";

interface IHookReceiver {
    function onTokenReceived() external;
}

/// 6-decimal ERC-20 mock with failure-injection knobs.
contract MockUSDC {
    enum Mode { Normal, ReturnFalse, NoReturn }

    error Blacklisted(address account);
    error InsufficientBalance();
    error InsufficientAllowance();

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public blacklisted;

    Mode public mode;
    address public reentryTarget;
    bytes public reentryData;
    bool public recipientHook;
    uint256 public transferFromCount;
    address public lastSpender;

    function decimals() external pure returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function blacklist(address account, bool on) external {
        blacklisted[account] = on;
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function setReentry(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryData = data;
    }

    function setRecipientHook(bool on) external {
        recipientHook = on;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        transferFromCount++;
        lastSpender = msg.sender;

        if (reentryTarget != address(0)) {
            (bool ok, bytes memory data) = reentryTarget.call(reentryData);
            if (!ok) _bubble(data);
        }

        if (blacklisted[from] || blacklisted[to]) {
            revert Blacklisted(blacklisted[from] ? from : to);
        }
        if (balanceOf[from] < amount) revert InsufficientBalance();
        if (allowance[from][msg.sender] < amount) revert InsufficientAllowance();

        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;

        if (recipientHook && to.code.length > 0) {
            (bool ok2, bytes memory data2) = to.call(abi.encodeCall(IHookReceiver.onTokenReceived, ()));
            if (!ok2) _bubble(data2);
        }

        if (mode == Mode.ReturnFalse) return false;
        if (mode == Mode.NoReturn) {
            assembly {
                return(0, 0)
            }
        }
        return true;
    }

    function _bubble(bytes memory data) private pure {
        assembly {
            revert(add(data, 32), mload(data))
        }
    }
}

contract MockDecimals18 {
    function decimals() external pure returns (uint8) {
        return 18;
    }
}

contract MockDecimalsReverts {
    function decimals() external pure returns (uint8) {
        revert("no decimals");
    }
}

contract ReentrantRecipient is IHookReceiver {
    SpendGate private immutable _gate;
    uint256 private immutable _id;
    uint128 private immutable _amount;

    constructor(SpendGate gate_, uint256 id_, uint128 amount_) {
        _gate = gate_;
        _id = id_;
        _amount = amount_;
    }

    function onTokenReceived() external {
        _gate.pay(_id, address(this), _amount, bytes32(0));
    }
}

abstract contract Base is Test {
    MockUSDC internal usdc;
    SpendGate internal gate;

    address internal O1;
    address internal O2;
    address internal A1;
    address internal A2;
    address internal R1;
    address internal R2;

    function setUp() public virtual {
        O1 = makeAddr("O1");
        O2 = makeAddr("O2");
        A1 = makeAddr("A1");
        A2 = makeAddr("A2");
        R1 = makeAddr("R1");
        R2 = makeAddr("R2");

        usdc = new MockUSDC();
        gate = new SpendGate(address(usdc));

        usdc.mint(O1, 1e12);
        vm.prank(O1);
        usdc.approve(address(gate), type(uint256).max);
        usdc.mint(O2, 1e12);
        vm.prank(O2);
        usdc.approve(address(gate), type(uint256).max);
    }

    function _arr(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    /// Default grant: O1 -> A1, 1 day, 100e6 / 40e6, no expiry, recipients [R1].
    function _grant() internal returns (uint256) {
        vm.prank(O1);
        return gate.createGrant(A1, 1 days, 100e6, 40e6, 0, _arr(R1));
    }

    function _pay(address who, uint256 id, address to, uint128 amt) internal {
        vm.prank(who);
        gate.pay(id, to, amt, bytes32(0));
    }

    function _snap(uint256 id) internal view returns (bytes32) {
        return keccak256(abi.encode(gate.grants(id)));
    }
}

contract SpendGateTest is Base {
    // ---------------------------------------------------------------- T1
    function test_T1_happyPath() public {
        uint256 id = _grant();
        assertEq(id, 1);

        vm.expectEmit(true, true, true, true, address(gate));
        emit ISpendGate.Paid(1, R1, 30e6, "inv-1", 0, 30e6);
        vm.prank(A1);
        gate.pay(1, R1, 30e6, "inv-1");

        assertEq(usdc.balanceOf(R1), 30e6);
        assertEq(usdc.balanceOf(O1), 1e12 - 30e6);
        assertEq(usdc.balanceOf(address(gate)), 0);
        assertEq(gate.grants(1).spentInWindow, 30e6);
        assertEq(gate.remaining(1), 70e6);
        assertEq(usdc.lastSpender(), address(gate));
    }

    // ---------------------------------------------------------------- T2
    function test_T2a_notAgent() public {
        _grant();
        vm.expectRevert(ISpendGate.NotAgent.selector);
        _pay(O1, 1, R1, 1);
        vm.expectRevert(ISpendGate.NotAgent.selector);
        _pay(makeAddr("rando"), 1, R1, 1);
        vm.expectRevert(ISpendGate.NotAgent.selector);
        _pay(A1, 0, R1, 1);
        vm.expectRevert(ISpendGate.NotAgent.selector);
        _pay(A1, 2, R1, 1);
    }

    function test_T2b_recipientNotAllowed() public {
        _grant();
        vm.expectRevert(ISpendGate.RecipientNotAllowed.selector);
        _pay(A1, 1, R2, 1);
    }

    function test_T2c_overPerPaymentCap() public {
        _grant();
        vm.expectRevert(ISpendGate.OverPerPaymentCap.selector);
        _pay(A1, 1, R1, 40e6 + 1);
        _pay(A1, 1, R1, 40e6);
        assertEq(usdc.balanceOf(R1), 40e6);
    }

    function test_T2d_overPeriodCap() public {
        _grant();
        _pay(A1, 1, R1, 40e6);
        _pay(A1, 1, R1, 40e6);
        vm.expectRevert(ISpendGate.OverPeriodCap.selector);
        _pay(A1, 1, R1, 20e6 + 1);
        _pay(A1, 1, R1, 20e6);
        assertEq(gate.remaining(1), 0);
    }

    function test_T2e_zeroAmount() public {
        _grant();
        vm.expectRevert(ISpendGate.ZeroAmount.selector);
        _pay(A1, 1, R1, 0);
    }

    function test_T2f_revoked() public {
        _grant();
        vm.prank(O1);
        gate.revoke(1);
        vm.expectRevert(ISpendGate.Revoked.selector);
        _pay(A1, 1, R1, 1);
        assertTrue(gate.grants(1).revoked);
    }

    function test_T2g_expired() public {
        vm.prank(O1);
        gate.createGrant(A1, 1 days, 100e6, 40e6, uint64(block.timestamp + 10), _arr(R1));
        vm.warp(block.timestamp + 10);
        vm.expectRevert(ISpendGate.Expired.selector);
        _pay(A1, 1, R1, 1);
    }

    function _cg(address agent, uint64 period, uint128 cap, uint128 ppc, uint64 exp, address[] memory rs)
        internal
        returns (uint256)
    {
        vm.prank(O1);
        return gate.createGrant(agent, period, cap, ppc, exp, rs);
    }

    function test_T2h_createGrantBadConfig() public {
        bytes4 bad = ISpendGate.BadConfig.selector;
        address[] memory rs = _arr(R1);

        vm.expectRevert(bad);
        _cg(A1, 0, 100, 10, 0, rs);
        vm.expectRevert(bad);
        _cg(A1, 1 days, 0, 10, 0, rs);
        vm.expectRevert(bad);
        _cg(A1, 1 days, 100, 0, 0, rs);
        vm.expectRevert(bad);
        _cg(A1, 10, 10, 11, 0, rs);

        vm.warp(1000);
        vm.expectRevert(bad);
        _cg(A1, 1 days, 100, 10, uint64(block.timestamp), rs);
        vm.expectRevert(bad);
        _cg(A1, 1 days, 100, 10, 500, rs);
        vm.expectRevert(bad);
        _cg(O1, 1 days, 100, 10, 0, rs);

        // Control: a valid config right after the failures succeeds.
        assertEq(_cg(A1, 1 days, 100, 10, 0, rs), 1);
    }

    function test_T2i_zeroAddress() public {
        bytes4 z = ISpendGate.ZeroAddress.selector;
        vm.expectRevert(z);
        _cg(address(0), 1 days, 100, 10, 0, _arr(R1));
        vm.expectRevert(z);
        _cg(A1, 1 days, 100, 10, 0, _arr(address(0)));

        _grant();
        vm.expectRevert(z);
        vm.prank(O1);
        gate.setRecipient(1, address(0), true);
    }

    function test_T2j_selfAndTokenRecipient() public {
        bytes4 bad = ISpendGate.BadConfig.selector;
        vm.expectRevert(bad);
        _cg(A1, 1 days, 100, 10, 0, _arr(address(gate)));
        vm.expectRevert(bad);
        _cg(A1, 1 days, 100, 10, 0, _arr(address(usdc)));

        _grant();
        vm.expectRevert(bad);
        vm.prank(O1);
        gate.setRecipient(1, address(gate), true);
        vm.expectRevert(bad);
        vm.prank(O1);
        gate.setRecipient(1, address(usdc), true);
    }

    function test_T2k_setCapsBadConfig() public {
        _grant();
        bytes4 bad = ISpendGate.BadConfig.selector;
        vm.startPrank(O1);
        vm.expectRevert(bad);
        gate.setCaps(1, 0, 0);
        vm.expectRevert(bad);
        gate.setCaps(1, 100, 0);
        vm.expectRevert(bad);
        gate.setCaps(1, 0, 10);
        vm.expectRevert(bad);
        gate.setCaps(1, 10, 11);
        vm.stopPrank();
    }

    function test_T2l_nonexistentIdNotOwner() public {
        _grant();
        bytes4 no = ISpendGate.NotOwner.selector;
        uint256[2] memory ids = [uint256(0), uint256(2)];
        for (uint256 i = 0; i < 2; ++i) {
            vm.startPrank(O1);
            vm.expectRevert(no);
            gate.setRecipient(ids[i], R1, true);
            vm.expectRevert(no);
            gate.setCaps(ids[i], 10, 10);
            vm.expectRevert(no);
            gate.revoke(ids[i]);
            vm.stopPrank();
        }
    }

    function test_T2m_constructor() public {
        MockDecimals18 d18 = new MockDecimals18();
        MockDecimalsReverts dRev = new MockDecimalsReverts();
        address eoa = makeAddr("eoa");

        vm.expectRevert(ISpendGate.ZeroAddress.selector);
        new SpendGate(address(0));
        vm.expectRevert(ISpendGate.BadConfig.selector);
        new SpendGate(eoa);
        vm.expectRevert(ISpendGate.BadConfig.selector);
        new SpendGate(address(d18));
        vm.expectRevert(ISpendGate.BadConfig.selector);
        new SpendGate(address(dRev));

        SpendGate ok = new SpendGate(address(usdc));
        assertTrue(address(ok).code.length > 0);
    }

    // ---------------------------------------------------------------- T3
    function test_T3_permissions() public {
        _grant();
        address rando = makeAddr("rando");
        address[2] memory callers = [A1, rando];
        for (uint256 i = 0; i < 2; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(ISpendGate.NotOwner.selector);
            gate.setRecipient(1, R2, true);
            vm.expectRevert(ISpendGate.NotOwner.selector);
            gate.setCaps(1, 1000, 1000);
            vm.expectRevert(ISpendGate.NotOwner.selector);
            gate.revoke(1);
            vm.stopPrank();
        }
        assertEq(gate.grants(1).periodCap, 100e6);

        vm.prank(O1);
        gate.setRecipient(1, R1, false);
        assertFalse(gate.isRecipient(1, R1));
        vm.expectRevert(ISpendGate.RecipientNotAllowed.selector);
        _pay(A1, 1, R1, 1);

        vm.startPrank(O1);
        gate.revoke(1);
        vm.expectRevert(ISpendGate.Revoked.selector);
        gate.setRecipient(1, R1, true);
        vm.expectRevert(ISpendGate.Revoked.selector);
        gate.setCaps(1, 10, 10);
        vm.expectRevert(ISpendGate.Revoked.selector);
        gate.revoke(1);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- T4
    function test_T4_expiryBoundary() public {
        uint64 st = uint64(block.timestamp);
        vm.prank(O1);
        gate.createGrant(A1, 1 days, 100e6, 40e6, st + 100, _arr(R1));

        vm.warp(st + 99);
        _pay(A1, 1, R1, 1);
        assertEq(usdc.balanceOf(R1), 1);

        vm.warp(st + 100);
        assertEq(gate.remaining(1), 0);
        vm.expectRevert(ISpendGate.Expired.selector);
        _pay(A1, 1, R1, 1);
    }

    function test_T4_windowEdge() public {
        uint64 st = uint64(block.timestamp);
        _grant();

        vm.warp(st + 1 days - 1);
        _pay(A1, 1, R1, 10e6);
        assertEq(gate.grants(1).windowIndex, 0);
        assertEq(gate.grants(1).spentInWindow, 10e6);

        vm.warp(st + 1 days);
        vm.expectEmit(true, true, true, true, address(gate));
        emit ISpendGate.Paid(1, R1, 10e6, bytes32(0), 1, 10e6);
        _pay(A1, 1, R1, 10e6);
        assertEq(gate.grants(1).windowIndex, 1);
    }

    function test_T4_events() public {
        vm.expectEmit(true, true, true, true, address(gate));
        emit ISpendGate.GrantCreated(1, O1, A1, 1 days, 100e6, 40e6, 0);
        vm.expectEmit(true, true, true, true, address(gate));
        emit ISpendGate.RecipientSet(1, R1, true);
        _grant();

        vm.expectEmit(true, true, true, true, address(gate));
        emit ISpendGate.RecipientSet(1, R2, true);
        vm.prank(O1);
        gate.setRecipient(1, R2, true);

        vm.expectEmit(true, true, true, true, address(gate));
        emit ISpendGate.CapsSet(1, 200e6, 50e6);
        vm.prank(O1);
        gate.setCaps(1, 200e6, 50e6);

        vm.expectEmit(true, true, true, true, address(gate));
        emit ISpendGate.Paid(1, R2, 7e6, "memo", 0, 7e6);
        vm.prank(A1);
        gate.pay(1, R2, 7e6, "memo");

        vm.expectEmit(true, true, true, true, address(gate));
        emit ISpendGate.GrantRevoked(1);
        vm.prank(O1);
        gate.revoke(1);
    }

    function test_T4_createGrantStoresFields() public {
        vm.warp(777);
        uint256 id = _grant();
        ISpendGate.Grant memory g = gate.grants(id);
        assertEq(g.owner, O1);
        assertEq(g.agent, A1);
        assertEq(g.period, 1 days);
        assertEq(g.start, 777);
        assertEq(g.periodCap, 100e6);
        assertEq(g.perPaymentCap, 40e6);
        assertEq(g.expiresAt, 0);
        assertFalse(g.revoked);
        assertEq(g.windowIndex, 0);
        assertEq(g.spentInWindow, 0);
    }

    // ---------------------------------------------------------------- T5
    function test_T5_rollover() public {
        uint64 st = uint64(block.timestamp);
        _grant();
        _pay(A1, 1, R1, 40e6);
        _pay(A1, 1, R1, 40e6);
        _pay(A1, 1, R1, 20e6);
        vm.expectRevert(ISpendGate.OverPeriodCap.selector);
        _pay(A1, 1, R1, 1);

        vm.warp(st + 1 days);
        _pay(A1, 1, R1, 1);
        assertEq(gate.grants(1).windowIndex, 1);

        // Skip empty windows: idx 6 is reached directly.
        vm.warp(st + 6 days);
        assertEq(gate.remaining(1), 100e6);
        vm.expectEmit(true, true, true, true, address(gate));
        emit ISpendGate.Paid(1, R1, 5e6, bytes32(0), 6, 5e6);
        _pay(A1, 1, R1, 5e6);
    }

    function test_T5_timestampBeforeStartPanics() public {
        vm.warp(1000);
        _grant();
        _pay(A1, 1, R1, 40e6);
        _pay(A1, 1, R1, 40e6);
        _pay(A1, 1, R1, 20e6);

        vm.warp(999);
        vm.expectRevert(stdError.arithmeticError);
        _pay(A1, 1, R1, 1);
    }

    // ---------------------------------------------------------------- T6
    function test_T6_twoXBoundary() public {
        uint64 st = uint64(block.timestamp);
        vm.prank(O1);
        gate.createGrant(A1, 1 days, 100e6, 100e6, 0, _arr(R1));

        vm.warp(st + 1 days - 1);
        _pay(A1, 1, R1, 100e6);
        vm.warp(st + 1 days);
        _pay(A1, 1, R1, 100e6);
        assertEq(usdc.balanceOf(R1), 200e6);
    }

    // ---------------------------------------------------------------- T7
    function test_T7_loweredCaps() public {
        _grant();
        _pay(A1, 1, R1, 40e6);
        _pay(A1, 1, R1, 30e6);

        vm.prank(O1);
        gate.setCaps(1, 50e6, 50e6);
        assertEq(gate.remaining(1), 0);
        assertEq(gate.grants(1).spentInWindow, 70e6);
        vm.expectRevert(ISpendGate.OverPeriodCap.selector);
        _pay(A1, 1, R1, 1);
        assertEq(gate.grants(1).spentInWindow, 70e6);

        vm.prank(O1);
        gate.setCaps(1, 100e6, 50e6);
        assertEq(gate.remaining(1), 30e6);
    }

    // ---------------------------------------------------------------- T8
    function test_T8_tokenReverts() public {
        uint256 id = _grant();

        // Blacklisted recipient.
        usdc.blacklist(R1, true);
        bytes32 s = _snap(id);
        uint256 bo = usdc.balanceOf(O1);
        vm.expectRevert(abi.encodeWithSelector(MockUSDC.Blacklisted.selector, R1));
        _pay(A1, id, R1, 5e6);
        assertEq(_snap(id), s);
        assertEq(usdc.balanceOf(O1), bo);
        assertEq(usdc.balanceOf(R1), 0);
        usdc.blacklist(R1, false);

        // Insufficient balance.
        address broke = makeAddr("broke");
        usdc.mint(broke, 5e6);
        vm.startPrank(broke);
        usdc.approve(address(gate), type(uint256).max);
        uint256 id2 = gate.createGrant(A1, 1 days, 100e6, 40e6, 0, _arr(R1));
        vm.stopPrank();
        bytes32 s2 = _snap(id2);
        vm.expectRevert(MockUSDC.InsufficientBalance.selector);
        _pay(A1, id2, R1, 6e6);
        assertEq(_snap(id2), s2);
        assertEq(usdc.balanceOf(broke), 5e6);
        // spendable: allowance max, balance 5e6.
        assertEq(gate.spendable(id2), 5e6);

        // Insufficient allowance.
        vm.prank(O1);
        usdc.approve(address(gate), 10e6);
        bytes32 s3 = _snap(id);
        vm.expectRevert(MockUSDC.InsufficientAllowance.selector);
        _pay(A1, id, R1, 11e6);
        assertEq(_snap(id), s3);
        assertEq(usdc.balanceOf(R1), 0);
        // spendable: allowance 10e6, balance 1e12.
        assertEq(gate.spendable(id), 10e6);
    }

    // ---------------------------------------------------------------- T9
    function test_T9_falseAndNoReturn() public {
        uint256 id = _grant();

        usdc.setMode(MockUSDC.Mode.ReturnFalse);
        bytes32 s = _snap(id);
        uint256 cnt = usdc.transferFromCount();
        vm.expectRevert(ISpendGate.TransferFailed.selector);
        _pay(A1, id, R1, 5e6);
        assertEq(_snap(id), s);
        assertEq(gate.grants(id).spentInWindow, 0);
        assertEq(usdc.transferFromCount(), cnt);

        usdc.setMode(MockUSDC.Mode.NoReturn);
        _pay(A1, id, R1, 5e6);
        assertEq(gate.grants(id).spentInWindow, 5e6);
        assertEq(usdc.balanceOf(R1), 5e6);
    }

    // ---------------------------------------------------------------- T10
    function test_T10_reentrancyViaToken() public {
        uint256 id = _grant();
        bytes32 s = _snap(id);

        usdc.setReentry(address(gate), abi.encodeCall(gate.pay, (id, R1, uint128(1), bytes32(0))));
        vm.expectRevert(ISpendGate.Reentrancy.selector);
        _pay(A1, id, R1, 5e6);
        assertEq(_snap(id), s);

        usdc.setReentry(address(gate), abi.encodeCall(gate.setCaps, (id, uint128(1), uint128(1))));
        vm.expectRevert(ISpendGate.Reentrancy.selector);
        _pay(A1, id, R1, 5e6);
        assertEq(_snap(id), s);
        assertEq(usdc.balanceOf(R1), 0);
    }

    function test_T10_reentrancyViaRecipientHook() public {
        _grant(); // id 1, keeps ids aligned
        ReentrantRecipient rr = new ReentrantRecipient(gate, 2, 1);
        vm.prank(O1);
        uint256 id = gate.createGrant(A1, 1 days, 100e6, 40e6, 0, _arr(address(rr)));
        assertEq(id, 2);

        usdc.setRecipientHook(true);
        bytes32 s = _snap(id);
        vm.expectRevert(ISpendGate.Reentrancy.selector);
        _pay(A1, id, address(rr), 5e6);
        assertEq(_snap(id), s);
        assertEq(usdc.balanceOf(address(rr)), 0);
    }

    // ---------------------------------------------------------------- T11
    function test_T11_twoOwners() public {
        _grant(); // #1: O1 / A1
        vm.prank(O2);
        gate.createGrant(A2, 1 days, 100e6, 40e6, 0, _arr(R1));

        vm.expectRevert(ISpendGate.NotAgent.selector);
        _pay(A1, 2, R1, 1e6);
        vm.expectRevert(ISpendGate.NotAgent.selector);
        _pay(A2, 1, R1, 1e6);

        _pay(A1, 1, R1, 10e6);
        assertEq(usdc.balanceOf(O1), 1e12 - 10e6);
        assertEq(usdc.balanceOf(O2), 1e12);
        assertEq(gate.grants(2).spentInWindow, 0);
    }

    // ---------------------------------------------------------------- T12
    function test_T12_views() public {
        assertEq(gate.remaining(0), 0);
        assertEq(gate.remaining(999), 0);
        assertEq(gate.spendable(0), 0);
        assertEq(gate.spendable(999), 0);
        ISpendGate.Grant memory z = gate.grants(999);
        assertEq(z.owner, address(0));
        assertEq(z.agent, address(0));
        assertEq(z.period, 0);
        assertEq(z.periodCap, 0);
        assertFalse(z.revoked);
        assertFalse(gate.isRecipient(999, R1));

        uint256 id = _grant();
        assertEq(gate.remaining(id), 100e6);
        assertEq(gate.spendable(id), 100e6);
        vm.prank(O1);
        gate.revoke(id);
        assertEq(gate.remaining(id), 0);
        assertEq(gate.spendable(id), 0);

        vm.prank(O1);
        uint256 id2 = gate.createGrant(A1, 1 days, 100e6, 40e6, uint64(block.timestamp + 50), _arr(R1));
        assertEq(gate.remaining(id2), 100e6);
        vm.warp(block.timestamp + 50);
        assertEq(gate.remaining(id2), 0);
        assertEq(gate.spendable(id2), 0);
    }

    // ---------------------------------------------------------------- T15
    function test_T15_abiSurface() public {
        string[9] memory sigs = [
            "createGrant(address,uint64,uint128,uint128,uint64,address[])",
            "setRecipient(uint256,address,bool)",
            "setCaps(uint256,uint128,uint128)",
            "revoke(uint256)",
            "pay(uint256,address,uint128,bytes32)",
            "grants(uint256)",
            "isRecipient(uint256,address)",
            "remaining(uint256)",
            "spendable(uint256)"
        ];
        bytes4[9] memory sels = [
            ISpendGate.createGrant.selector,
            ISpendGate.setRecipient.selector,
            ISpendGate.setCaps.selector,
            ISpendGate.revoke.selector,
            ISpendGate.pay.selector,
            ISpendGate.grants.selector,
            ISpendGate.isRecipient.selector,
            ISpendGate.remaining.selector,
            ISpendGate.spendable.selector
        ];

        string memory path;
        try vm.getArtifactPathByDeployedCode(address(gate).code) returns (string memory p) {
            path = p;
        } catch {
            path = "out/SpendGate.sol/SpendGate.json";
        }
        string memory json = vm.readFile(path);
        string[] memory keys = vm.parseJsonKeys(json, ".methodIdentifiers");

        assertEq(keys.length, sigs.length, "selector set size");
        for (uint256 i = 0; i < sigs.length; ++i) {
            bool found;
            for (uint256 j = 0; j < keys.length; ++j) {
                if (keccak256(bytes(keys[j])) == keccak256(bytes(sigs[i]))) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, sigs[i]);

            string memory val =
                vm.parseJsonString(json, string.concat(".methodIdentifiers[\"", sigs[i], "\"]"));
            bytes memory raw = vm.parseBytes(string.concat("0x", val));
            assertEq(bytes4(raw), sels[i], sigs[i]);
            assertEq(bytes4(keccak256(bytes(sigs[i]))), sels[i], sigs[i]);
        }

        // No receive / fallback, no hidden getter.
        vm.deal(address(this), 1);
        (bool okEth,) = address(gate).call{value: 1}("");
        assertFalse(okEth);
        (bool okUsdc,) = address(gate).call(abi.encodeWithSelector(bytes4(keccak256("usdc()"))));
        assertFalse(okUsdc);
    }
}

contract SpendGateFuzzTest is Base {
    uint256 private constant CAP = 1000;
    uint256 private constant PPC = 600;

    struct Model {
        uint256 start;
        uint256 period;
        uint256 n;
        uint256[5] pt;
        uint256[5] pa;
    }

    // ---------------------------------------------------------------- T13a
    function testFuzz_payWithinCaps(uint128 capIn, uint128 ppcIn, uint128 amtIn) public {
        uint128 cap = uint128(bound(capIn, 1, 1e15));
        uint128 ppc = uint128(bound(ppcIn, 1, cap));
        uint128 amt = uint128(bound(amtIn, 0, 2e15));
        usdc.mint(O1, 1e16);

        vm.prank(O1);
        uint256 id = gate.createGrant(A1, 1 days, cap, ppc, 0, _arr(R1));

        bool shouldSucceed = amt > 0 && amt <= ppc;
        if (amt == 0) {
            vm.expectRevert(ISpendGate.ZeroAmount.selector);
        } else if (amt > ppc) {
            vm.expectRevert(ISpendGate.OverPerPaymentCap.selector);
        }
        vm.prank(A1);
        gate.pay(id, R1, amt, bytes32(0));

        if (shouldSucceed) {
            assertEq(gate.remaining(id), cap - amt);
        } else {
            assertEq(gate.remaining(id), cap);
        }
    }

    // ---------------------------------------------------------------- T13b
    function testFuzz_windowModel(uint64 periodIn, uint32[5] memory dts, uint128[5] memory amts) public {
        uint64 period = uint64(bound(periodIn, 1, 365 days));
        vm.prank(O1);
        uint256 id = gate.createGrant(A1, period, uint128(CAP), uint128(PPC), 0, _arr(R1));

        Model memory m;
        m.start = block.timestamp;
        m.period = period;

        uint256 ts = block.timestamp;
        for (uint256 i = 0; i < 5; ++i) {
            ts += bound(uint256(dts[i]), 0, 3 * uint256(period));
            vm.warp(ts);
            _modelStep(m, id, ts, bound(uint256(amts[i]), 0, 800));
        }
    }

    /// Reference model: the spent amount of a window is the sum of the successful payments
    /// whose timestamp lies in [start + idx*period, start + (idx+1)*period). It does not
    /// reuse the contract's windowIndex / spentInWindow bookkeeping.
    function _modelStep(Model memory m, uint256 id, uint256 ts, uint256 amt) internal {
        uint256 spent = _windowSpent(m, ts);
        bool ok = false;
        if (amt == 0) {
            vm.expectRevert(ISpendGate.ZeroAmount.selector);
        } else if (amt > PPC) {
            vm.expectRevert(ISpendGate.OverPerPaymentCap.selector);
        } else if (spent + amt > CAP) {
            vm.expectRevert(ISpendGate.OverPeriodCap.selector);
        } else {
            ok = true;
        }
        vm.prank(A1);
        gate.pay(id, R1, uint128(amt), bytes32(0));

        if (ok) {
            m.pt[m.n] = ts;
            m.pa[m.n] = amt;
            ++m.n;
        }
        uint256 spentNow = _windowSpent(m, ts);
        assertEq(gate.remaining(id), CAP > spentNow ? CAP - spentNow : 0);
    }

    function _windowSpent(Model memory m, uint256 ts) internal pure returns (uint256 sum) {
        uint256 idxNow = (ts - m.start) / m.period;
        for (uint256 i = 0; i < m.n; ++i) {
            if ((m.pt[i] - m.start) / m.period == idxNow) sum += m.pa[i];
        }
    }
}

/// Stateful driver for the invariant suite. It never relies on assert: every violation
/// is recorded in `violation[k]` (k = invariant number) and checked by the test contract.
contract Handler is Test {
    struct Rec {
        address owner;
        address agent;
        uint64 period;
        uint64 start;
        bool revoked;
    }

    struct Pre {
        ISpendGate.Grant g;
        bool wasRecipient;
        uint256 idx;
    }

    SpendGate public gate;
    MockUSDC public usdc;

    uint256 public constant OWNER_MINT = 1e15;

    address[2] public owners;
    address[3] public agents;
    address[4] public recipients;
    address public stranger;

    uint256 public ghostGrants;
    uint256 public ghostPaySuccess;
    uint256 public ghostPayRevert;
    // Same counters, but only for calls driven by the fuzzer (the `_boot` seed is excluded),
    // so the non-vacuity check cannot be satisfied by pre-seeded data alone.
    uint256 public fuzzPaySuccess;
    uint256 public fuzzPayRevert;
    bool public bootstrapped;
    bool private _booting;

    bool[10] public violation;

    mapping(uint256 => Rec) public rec;
    mapping(address => int256) public ledger;
    // The handler's own record of each grant's current period cap. I3 is checked against
    // this, never against the cap read back from the contract under test.
    mapping(uint256 => uint256) public capNow;
    mapping(uint256 => mapping(uint256 => uint256)) public maxCap;
    mapping(uint256 => mapping(uint256 => uint256)) public paid;
    mapping(uint256 => mapping(uint256 => bool)) private _isTouched;
    uint256[] public touchedIds;
    uint256[] public touchedIdx;

    constructor(SpendGate gate_, MockUSDC usdc_) {
        gate = gate_;
        usdc = usdc_;
        owners = [makeAddr("hOwner1"), makeAddr("hOwner2")];
        agents = [makeAddr("hAgent1"), makeAddr("hAgent2"), makeAddr("hAgent3")];
        recipients = [makeAddr("hR1"), makeAddr("hR2"), makeAddr("hR3"), makeAddr("hR4")];
        stranger = makeAddr("hStranger");
        for (uint256 i = 0; i < 2; ++i) {
            usdc.mint(owners[i], OWNER_MINT);
            vm.prank(owners[i]);
            usdc.approve(address(gate), type(uint256).max);
        }
    }

    function touchedLength() external view returns (uint256) {
        return touchedIds.length;
    }

    // ------------------------------------------------------------ actions
    function actCreateGrant(uint256 seed, uint256 period, uint256 cap, uint256 ppc, uint256 expSeed) external {
        _boot();
        cap = bound(cap, 1, 1e12);
        ppc = _boundPpc(ppc, cap);
        period = bound(period, 1, 30 days);
        uint256 expiry = expSeed % 10 < 3 ? block.timestamp + bound(expSeed / 10, 1, 60 days) : 0;
        _create(owners[seed % 2], agents[(seed / 2) % 3], period, cap, ppc, expiry, _pickRecipients(seed / 6));
    }

    function actSetRecipient(uint256 idSeed, uint256 callerSeed, uint256 rSeed, bool allowed) external {
        _boot();
        uint256 id = 1 + idSeed % ghostGrants;
        address caller = _ownerOrStranger(id, callerSeed);
        vm.prank(caller);
        try gate.setRecipient(id, recipients[rSeed % 4], allowed) {
            _checkOwnerAction(id, caller);
        } catch {}
    }

    function actSetCaps(uint256 idSeed, uint256 callerSeed, uint256 cap, uint256 ppc) external {
        _boot();
        uint256 id = 1 + idSeed % ghostGrants;
        address caller = _ownerOrStranger(id, callerSeed);
        cap = bound(cap, 1, 1e12);
        ppc = _boundPpc(ppc, cap);

        uint256 idx = _idx(id);
        _noteCap(id, idx, capNow[id]);

        vm.prank(caller);
        try gate.setCaps(id, uint128(cap), uint128(ppc)) {
            _checkOwnerAction(id, caller);
            capNow[id] = cap;
            _noteCap(id, idx, cap);
        } catch {}
    }

    function actPay(uint256 idSeed, uint256 callerSeed, uint256 toSeed, uint256 amount, bytes32 memo) external {
        _boot();
        uint256 id = 1 + idSeed % ghostGrants;
        ISpendGate.Grant memory g = gate.grants(id);
        uint256 pick = callerSeed % 10;
        address caller = pick < 8 ? g.agent : (pick == 8 ? g.owner : stranger);
        // A third of the time pay exactly the per-payment cap, so a handful of payments reach
        // the period cap; otherwise anything from zero to a little over the per-payment cap.
        amount = amount % 3 == 0 ? g.perPaymentCap : bound(amount, 0, uint256(g.perPaymentCap) * 5 / 4 + 1);
        // Three times in four, aim at a recipient the grant currently allows, so successful
        // payments are common enough to exercise the window accounting; otherwise any recipient.
        address to = recipients[toSeed % 4];
        if ((toSeed / 4) % 4 != 0) {
            for (uint256 j = 0; j < 4; ++j) {
                address r = recipients[(toSeed + j) % 4];
                if (gate.isRecipient(id, r)) {
                    to = r;
                    break;
                }
            }
        }
        _doPay(id, caller, to, amount, memo);
    }

    function actRevoke(uint256 idSeed, uint256 callerSeed) external {
        _boot();
        uint256 id = 1 + idSeed % ghostGrants;
        address caller = _ownerOrStranger(id, callerSeed);
        vm.prank(caller);
        try gate.revoke(id) {
            if (caller != rec[id].owner) _flag(9);
            if (rec[id].revoked) _flag(5);
            rec[id].revoked = true;
        } catch {}
    }

    function actWarp(uint256 dt) external {
        _boot();
        vm.warp(block.timestamp + bound(dt, 0, 40 days));
    }

    function actApprove(uint256 oSeed, uint256 amt) external {
        _boot();
        uint256 value = amt % 4 == 0 ? type(uint256).max : bound(amt, 0, 2e12);
        vm.prank(owners[oSeed % 2]);
        usdc.approve(address(gate), value);
    }

    function actBlacklist(uint256 seed) external {
        _boot();
        uint256 i = seed % 6;
        address target = i < 4 ? recipients[i] : owners[i - 4];
        // Mostly clears the flag so that payments keep succeeding.
        usdc.blacklist(target, (seed / 6) % 5 == 0);
    }

    // ------------------------------------------------------------ internals
    /// Seeds one successful and one failing payment in every run, so the non-vacuity
    /// counters are never zero for a run in which the handler was called at all.
    function _boot() internal {
        if (bootstrapped) return;
        bootstrapped = true;
        _booting = true;
        address[] memory rs = new address[](1);
        rs[0] = recipients[0];
        uint256 id = _create(owners[0], agents[0], 30 days, 1e12, 1e9, 0, rs);
        _doPay(id, agents[0], recipients[0], 1000, bytes32(0));
        _doPay(id, stranger, recipients[0], 1000, bytes32(0));
        _booting = false;
    }

    /// Half the time the per-payment cap is at least a quarter of the period cap, so a few
    /// payments can reach the period cap and the period-cap check is actually exercised.
    function _boundPpc(uint256 ppc, uint256 cap) internal pure returns (uint256) {
        if (ppc % 2 == 0) return bound(ppc, 1, cap);
        return bound(ppc, cap / 4 == 0 ? 1 : cap / 4, cap);
    }

    function _idx(uint256 id) internal view returns (uint256) {
        return (block.timestamp - rec[id].start) / rec[id].period;
    }

    function _flag(uint256 k) internal {
        violation[k] = true;
    }

    function _pickRecipients(uint256 seed) internal view returns (address[] memory rs) {
        uint256 r = seed % 10;
        uint256 n = r < 1 ? 0 : (r < 6 ? 1 : 2);
        rs = new address[](n);
        for (uint256 j = 0; j < n; ++j) {
            rs[j] = recipients[(seed / 10 + j) % 4];
        }
    }

    function _ownerOrStranger(uint256 id, uint256 callerSeed) internal view returns (address) {
        return callerSeed % 10 < 8 ? rec[id].owner : stranger;
    }

    function _create(
        address owner_,
        address agent,
        uint256 period,
        uint256 cap,
        uint256 ppc,
        uint256 expiry,
        address[] memory rs
    ) internal returns (uint256) {
        vm.prank(owner_);
        try gate.createGrant(agent, uint64(period), uint128(cap), uint128(ppc), uint64(expiry), rs) returns (
            uint256 id
        ) {
            ghostGrants++;
            if (id != ghostGrants) _flag(9);
            rec[id] = Rec(owner_, agent, uint64(period), uint64(block.timestamp), false);
            capNow[id] = cap;
            _noteCap(id, 0, cap);
            return id;
        } catch {
            return 0;
        }
    }

    function _noteCap(uint256 id, uint256 idx, uint256 cap) internal {
        if (cap > maxCap[id][idx]) maxCap[id][idx] = cap;
        if (!_isTouched[id][idx]) {
            _isTouched[id][idx] = true;
            touchedIds.push(id);
            touchedIdx.push(idx);
        }
    }

    function _checkOwnerAction(uint256 id, address caller) internal {
        if (caller != rec[id].owner) _flag(9);
        if (rec[id].revoked) _flag(5);
    }

    function _doPay(uint256 id, address caller, address to, uint256 amount, bytes32 memo) internal {
        Pre memory p;
        p.g = gate.grants(id);
        p.wasRecipient = gate.isRecipient(id, to);
        p.idx = _idx(id);
        _noteCap(id, p.idx, capNow[id]);

        vm.prank(caller);
        try gate.pay(id, to, uint128(amount), memo) {
            _onPaySuccess(id, caller, to, amount, p);
        } catch (bytes memory reason) {
            _onPayRevert(id, amount, reason, p);
        }
    }

    function _onPaySuccess(uint256 id, address caller, address to, uint256 amount, Pre memory p) internal {
        ISpendGate.Grant memory g = p.g;
        ghostPaySuccess++;
        if (!_booting) fuzzPaySuccess++;

        if (!p.wasRecipient) _flag(1);
        if (caller != g.agent) _flag(2);
        if (amount == 0 || amount > g.perPaymentCap) _flag(4);
        if (g.revoked || rec[id].revoked) _flag(5);
        if (g.expiresAt != 0 && block.timestamp >= g.expiresAt) _flag(6);

        // I3 against the handler's own model: what this window already paid plus this
        // payment must fit the cap the handler last set.
        if (paid[id][p.idx] + amount > capNow[id]) _flag(3);

        paid[id][p.idx] += amount;
        // Window bookkeeping must match the model: the window index is the current one and
        // the stored spend is exactly what was paid in it (catches "never rolls" and
        // "rolls on every payment").
        ISpendGate.Grant memory after_ = gate.grants(id);
        if (after_.windowIndex != p.idx || after_.spentInWindow != paid[id][p.idx]) _flag(3);
        ledger[g.owner] -= int256(amount);
        ledger[to] += int256(amount);
    }

    function _onPayRevert(uint256 id, uint256 amount, bytes memory reason, Pre memory p) internal {
        ghostPayRevert++;
        if (!_booting) fuzzPayRevert++;
        ISpendGate.Grant memory after_ = gate.grants(id);
        if (after_.windowIndex != p.g.windowIndex || after_.spentInWindow != p.g.spentInWindow) _flag(8);
        // The other side of I3: a payment rejected as over the period cap must really be over
        // it by the handler's own model (catches a window that never rolls over).
        if (bytes4(reason) == ISpendGate.OverPeriodCap.selector && paid[id][p.idx] + amount <= capNow[id]) {
            _flag(3);
        }
    }
}

contract SpendGateInvariantTest is StdInvariant, Test {
    MockUSDC internal usdc;
    SpendGate internal gate;
    Handler internal h;

    function setUp() public {
        usdc = new MockUSDC();
        gate = new SpendGate(address(usdc));
        h = new Handler(gate, usdc);

        bytes4[] memory sels = new bytes4[](8);
        sels[0] = Handler.actCreateGrant.selector;
        sels[1] = Handler.actSetRecipient.selector;
        sels[2] = Handler.actSetCaps.selector;
        sels[3] = Handler.actPay.selector;
        sels[4] = Handler.actRevoke.selector;
        sels[5] = Handler.actWarp.selector;
        sels[6] = Handler.actApprove.selector;
        sels[7] = Handler.actBlacklist.selector;
        targetContract(address(h));
        targetSelector(FuzzSelector({addr: address(h), selectors: sels}));
    }

    // Plumbing check: every run has grants, a payment success, a payment revert, and at least
    // one tracked window. These counts include the `_boot` seed, so they show the handler and
    // its bookkeeping work; they do not show that the fuzzer itself reached a successful
    // payment in every run (it does not always: a 32-call run can contain no successful pay).
    // Evidence that the invariants actually bite comes from the mutation arms recorded in
    // HANDOFF.md: each of DESIGN section 7 item 11's five broken implementations turns its
    // invariant red.
    function afterInvariant() public view {
        assertGt(h.ghostGrants(), 0, "no grants created");
        assertGt(h.ghostPaySuccess(), 0, "no successful pay");
        assertGt(h.ghostPayRevert(), 0, "no reverted pay");
        assertGt(h.touchedLength(), 0, "no tracked windows");
    }

    /// Fixed-sequence smoke run of the handler (also guards the handler itself).
    function test_handlerSmoke() public {
        h.actCreateGrant(0, 1 days, 1e9, 1e8, 0);
        h.actSetRecipient(1, 0, 0, true);
        h.actPay(1, 0, 0, 1e6, bytes32(0));
        h.actSetCaps(0, 0, 1e9, 1e8);
        h.actWarp(2 days);
        h.actPay(0, 0, 0, 1e6, bytes32(0));
        h.actRevoke(0, 0);
        h.actPay(0, 0, 0, 1e6, bytes32(0));

        assertGt(h.ghostGrants(), 0);
        assertGt(h.ghostPaySuccess(), 0);
        assertGt(h.ghostPayRevert(), 0);
        assertGt(h.touchedLength(), 0);
        assertGt(h.fuzzPaySuccess(), 0, "no non-boot successful pay");
        assertGt(h.fuzzPayRevert(), 0, "no non-boot reverted pay");
        for (uint256 k = 1; k < 10; ++k) {
            assertFalse(h.violation(k), "violation flag set");
        }
    }

    function invariant_I1_onlyWhitelistedViaGateAllowance() public view {
        assertFalse(h.violation(1));
        assertEq(usdc.transferFromCount(), h.ghostPaySuccess());
        if (usdc.transferFromCount() > 0) assertEq(usdc.lastSpender(), address(gate));
        for (uint256 i = 0; i < 2; ++i) {
            address o = h.owners(i);
            assertEq(int256(usdc.balanceOf(o)), int256(h.OWNER_MINT()) + h.ledger(o));
        }
        for (uint256 i = 0; i < 4; ++i) {
            address r = h.recipients(i);
            assertEq(int256(usdc.balanceOf(r)), h.ledger(r));
        }
    }

    function invariant_I2_onlyAgentPays() public view {
        assertFalse(h.violation(2));
    }

    function invariant_I3_windowSpendBoundedByCap() public view {
        assertFalse(h.violation(3));
        uint256 n = h.touchedLength();
        for (uint256 i = 0; i < n; ++i) {
            uint256 id = h.touchedIds(i);
            uint256 idx = h.touchedIdx(i);
            assertLe(h.paid(id, idx), h.maxCap(id, idx));
        }
    }

    function invariant_I4_amountWithinPerPaymentCap() public view {
        assertFalse(h.violation(4));
    }

    function invariant_I5_revokedIsTerminal() public view {
        assertFalse(h.violation(5));
        uint256 n = h.ghostGrants();
        for (uint256 id = 1; id <= n; ++id) {
            (,,,, bool revoked) = h.rec(id);
            if (revoked) assertTrue(gate.grants(id).revoked);
        }
    }

    function invariant_I6_noPayAfterExpiry() public view {
        assertFalse(h.violation(6));
    }

    function invariant_I7_gateHoldsNoFunds() public view {
        assertEq(usdc.balanceOf(address(gate)), 0);
    }

    function invariant_I8_revertedPayChangesNothing() public view {
        assertFalse(h.violation(8));
    }

    function invariant_I9_immutableFieldsAndOwnerOnly() public view {
        assertFalse(h.violation(9));
        uint256 n = h.ghostGrants();
        for (uint256 id = 1; id <= n; ++id) {
            (address o, address a, uint64 period, uint64 start,) = h.rec(id);
            ISpendGate.Grant memory g = gate.grants(id);
            assertEq(g.owner, o);
            assertEq(g.agent, a);
            assertEq(g.period, period);
            assertEq(g.start, start);
        }
    }
}
