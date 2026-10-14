// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// All amounts are ERC-20 USDC 6-decimal units.
interface ISpendGate {
    struct Grant {
        address owner;         // = createGrant msg.sender, immutable
        address agent;         // only caller of pay, immutable
        uint64  period;        // seconds, > 0, immutable
        uint64  start;         // = uint64(block.timestamp) at creation, immutable
        uint128 periodCap;     // > 0
        uint128 perPaymentCap; // 0 < perPaymentCap <= periodCap
        uint64  expiresAt;     // 0 = never; else > start
        bool    revoked;       // once true, never false
        uint64  windowIndex;   // window that spentInWindow belongs to
        uint128 spentInWindow;
    }

    error NotOwner();
    error NotAgent();
    error Revoked();
    error Expired();
    error RecipientNotAllowed();
    error OverPerPaymentCap();
    error OverPeriodCap();
    error ZeroAmount();
    error ZeroAddress();
    error BadConfig();
    error TransferFailed();
    error Reentrancy(); // resolution R3: not in DESIGN's error list; errors add no function selectors

    event GrantCreated(uint256 indexed grantId, address indexed owner, address indexed agent,
                       uint64 period, uint128 periodCap, uint128 perPaymentCap, uint64 expiresAt);
    event RecipientSet(uint256 indexed grantId, address indexed recipient, bool allowed);
    event CapsSet(uint256 indexed grantId, uint128 periodCap, uint128 perPaymentCap);
    event GrantRevoked(uint256 indexed grantId);
    event Paid(uint256 indexed grantId, address indexed to, uint128 amount, bytes32 memo,
               uint64 windowIndex, uint128 spentInWindow);

    function createGrant(address agent, uint64 period, uint128 periodCap,
                         uint128 perPaymentCap, uint64 expiresAt,
                         address[] calldata recipients) external returns (uint256 grantId);
    function setRecipient(uint256 grantId, address recipient, bool allowed) external;
    function setCaps(uint256 grantId, uint128 periodCap, uint128 perPaymentCap) external;
    function revoke(uint256 grantId) external;
    function pay(uint256 grantId, address to, uint128 amount, bytes32 memo) external;

    function grants(uint256 grantId) external view returns (Grant memory);
    function isRecipient(uint256 grantId, address to) external view returns (bool);
    function remaining(uint256 grantId) external view returns (uint128);
    function spendable(uint256 grantId) external view returns (uint128);
}

/// Minimal read-only view of the token, used only by `spendable`.
interface IERC20Min {
    function allowance(address owner, address spender) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

contract SpendGate is ISpendGate {
    address private immutable _usdc;
    uint256 private _nextId; // last assigned id; first grant gets 1
    mapping(uint256 => Grant) private _grants;
    mapping(uint256 => mapping(address => bool)) private _recipients;
    bool private transient _locked;

    // transferFrom(address,address,uint256)
    bytes4 private constant _TRANSFER_FROM = 0x23b872dd;

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    constructor(address usdc_) {
        if (usdc_ == address(0)) revert ZeroAddress();
        if (usdc_.code.length == 0) revert BadConfig();
        (bool ok, bytes memory ret) = usdc_.staticcall(abi.encodeWithSignature("decimals()"));
        if (!ok || ret.length < 32 || abi.decode(ret, (uint256)) != 6) revert BadConfig();
        _usdc = usdc_;
    }

    function createGrant(address agent, uint64 period, uint128 periodCap, uint128 perPaymentCap,
                         uint64 expiresAt, address[] calldata recipients)
        external nonReentrant returns (uint256 grantId)
    {
        if (agent == address(0)) revert ZeroAddress();
        if (agent == msg.sender) revert BadConfig();
        if (period == 0 || periodCap == 0 || perPaymentCap == 0 || perPaymentCap > periodCap) {
            revert BadConfig();
        }
        if (expiresAt != 0 && expiresAt <= block.timestamp) revert BadConfig();

        uint256 n = recipients.length;
        for (uint256 i = 0; i < n; ++i) {
            _checkRecipient(recipients[i]);
        }

        grantId = ++_nextId;
        _grants[grantId] = Grant({
            owner: msg.sender,
            agent: agent,
            period: period,
            start: uint64(block.timestamp),
            periodCap: periodCap,
            perPaymentCap: perPaymentCap,
            expiresAt: expiresAt,
            revoked: false,
            windowIndex: 0,
            spentInWindow: 0
        });

        emit GrantCreated(grantId, msg.sender, agent, period, periodCap, perPaymentCap, expiresAt);
        for (uint256 i = 0; i < n; ++i) {
            address r = recipients[i];
            _recipients[grantId][r] = true;
            emit RecipientSet(grantId, r, true);
        }
    }

    function setRecipient(uint256 grantId, address recipient, bool allowed) external nonReentrant {
        _requireActiveOwner(grantId);
        if (allowed) _checkRecipient(recipient);
        _recipients[grantId][recipient] = allowed;
        emit RecipientSet(grantId, recipient, allowed);
    }

    function setCaps(uint256 grantId, uint128 periodCap, uint128 perPaymentCap) external nonReentrant {
        Grant storage g = _requireActiveOwner(grantId);
        if (periodCap == 0 || perPaymentCap == 0 || perPaymentCap > periodCap) revert BadConfig();
        g.periodCap = periodCap;
        g.perPaymentCap = perPaymentCap;
        emit CapsSet(grantId, periodCap, perPaymentCap);
    }

    function revoke(uint256 grantId) external nonReentrant {
        Grant storage g = _requireActiveOwner(grantId);
        g.revoked = true;
        emit GrantRevoked(grantId);
    }

    function pay(uint256 grantId, address to, uint128 amount, bytes32 memo) external nonReentrant {
        Grant storage g = _grants[grantId];
        if (msg.sender != g.agent) revert NotAgent();
        if (g.revoked) revert Revoked();
        if (g.expiresAt != 0 && block.timestamp >= g.expiresAt) revert Expired();
        if (amount == 0) revert ZeroAmount();
        if (!_recipients[grantId][to]) revert RecipientNotAllowed();
        if (amount > g.perPaymentCap) revert OverPerPaymentCap();

        // Checked arithmetic on purpose: a timestamp before `start` panics (fail closed).
        uint256 idx = (block.timestamp - g.start) / g.period;
        uint256 spent = (idx == g.windowIndex) ? g.spentInWindow : 0;
        uint256 newSpent = spent + amount;
        if (newSpent > g.periodCap) revert OverPeriodCap();

        // Effects before the single external call.
        g.windowIndex = uint64(idx);
        g.spentInWindow = uint128(newSpent);

        (bool ok, bytes memory ret) =
            _usdc.call(abi.encodeWithSelector(_TRANSFER_FROM, g.owner, to, uint256(amount)));
        if (!ok) {
            if (ret.length == 0) revert TransferFailed();
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
        if (ret.length != 0) {
            if (ret.length < 32 || abi.decode(ret, (uint256)) != 1) revert TransferFailed();
        }

        emit Paid(grantId, to, amount, memo, g.windowIndex, g.spentInWindow);
    }

    function grants(uint256 grantId) external view returns (Grant memory) {
        return _grants[grantId];
    }

    function isRecipient(uint256 grantId, address to) external view returns (bool) {
        return _recipients[grantId][to];
    }

    function remaining(uint256 grantId) external view returns (uint128) {
        return _remaining(grantId);
    }

    function spendable(uint256 grantId) external view returns (uint128) {
        uint128 rem = _remaining(grantId);
        if (rem == 0) return 0;
        address owner_ = _grants[grantId].owner;
        uint256 allowed = IERC20Min(_usdc).allowance(owner_, address(this));
        uint256 bal = IERC20Min(_usdc).balanceOf(owner_);
        uint256 m = rem;
        if (allowed < m) m = allowed;
        if (bal < m) m = bal;
        return uint128(m);
    }

    function _remaining(uint256 grantId) private view returns (uint128) {
        Grant storage g = _grants[grantId];
        if (g.owner == address(0) || g.revoked) return 0;
        if (g.expiresAt != 0 && block.timestamp >= g.expiresAt) return 0;
        uint256 idx = (block.timestamp - g.start) / g.period;
        if (idx != g.windowIndex) return g.periodCap;
        return g.spentInWindow >= g.periodCap ? 0 : g.periodCap - g.spentInWindow;
    }

    /// A1 + A2: caller must be the owner and the grant must not be revoked.
    function _requireActiveOwner(uint256 grantId) private view returns (Grant storage g) {
        g = _grants[grantId];
        if (g.owner != msg.sender) revert NotOwner();
        if (g.revoked) revert Revoked();
    }

    /// C4: a recipient can never be zero, this contract, or the token itself.
    function _checkRecipient(address r) private view {
        if (r == address(0)) revert ZeroAddress();
        if (r == address(this) || r == _usdc) revert BadConfig();
    }
}
