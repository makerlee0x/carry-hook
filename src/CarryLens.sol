// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

interface IExtsload {
    function extsload(bytes32 slot) external view returns (bytes32);
}

/// @dev The parts of CarryFollowerVault (per-market hooks) and ICarryHook the lens reads.
interface ILensVault {
    struct Market {
        address token;
        address hook;
        bytes32 pool;
        bool active;
        uint256 cap;
        uint256 lent;
        uint256 shares;
        uint256 owed;
    }

    function markets(uint256 market) external view returns (Market memory);
}

interface ILensHook {
    function sharesValue(bytes32 pool, uint256 shares) external view returns (uint256);
}

/// @title CarryLens
/// @notice Carry: read-only views of a CarryStrategy pool's settings for the keeper and the site, read through the
///         hook's `extsload` (the hook has no room left for more getters under EIP-170). The slot layout below is
///         the hook's storage layout (`forge inspect CarryStrategy storageLayout`); `test_lensMatchesTheHook` checks
///         it against the hook's own views, so a layout change fails the tests.
contract CarryLens {
    /// @dev Storage slot of `CarryStrategy.pools` (mapping(PoolId => Pool)).
    uint256 internal constant POOLS_SLOT = 1;
    // offsets inside a Pool
    uint256 internal constant SRC = 2; // Source: 4 slots
    uint256 internal constant JAR_X = 10;
    uint256 internal constant JAR_Y = 11;

    struct Leader {
        uint8 kind; // 1 v2, 2 v3, 3 v4
        bool coinIs0;
        address target;
        bytes32 v4Id;
        uint8 kind2; // leg 2 kind, 0 = none
        bool xIs0;
        address target2;
        bytes32 v4Id2;
    }

    struct PoolInfo {
        bool exists;
        bool live;
        bool coinIs0; // the coin is currency0 of the Carry pool
        uint24 fee; // pips
        address coin;
        uint16 edgeBps; // v0.3
        uint16 protoFee; // v0.3, pips
        bool paused; // v0.3
        address quote;
        uint32 lamPpm; // v0.3
        Leader leader;
        uint256 jarX; // tip jar, coin raw
        uint256 jarY; // tip jar, quote raw
    }

    /// @notice Display only, never used for share pricing: the lenders' claim on a Carry market's positions (USDG
    ///         lent plus owed) less what its lender-matched lots are worth now at the pool's mark, all lots together
    ///         (0 when they cover it). Moved here from the vault (round-5 audit, to make room for its outflow checks).
    function shortfallOf(address vault, uint256 market) external view returns (uint256) {
        ILensVault.Market memory m = ILensVault(vault).markets(market);
        uint256 need = m.lent + m.owed;
        if (need == 0) return 0;
        uint256 worth = ILensHook(m.hook).sharesValue(m.pool, m.shares);
        return need > worth ? need - worth : 0;
    }

    function poolInfo(address hook, PoolId id) external view returns (PoolInfo memory i) {
        uint256 base = uint256(keccak256(abi.encode(PoolId.unwrap(id), POOLS_SLOT)));
        IExtsload h = IExtsload(hook);
        uint256 s0 = uint256(h.extsload(bytes32(base)));
        i.exists = s0 & 0xff != 0;
        i.live = (s0 >> 8) & 0xff != 0;
        i.coinIs0 = (s0 >> 16) & 0xff != 0;
        i.fee = uint24(s0 >> 24);
        i.coin = address(uint160(s0 >> 48));
        i.edgeBps = uint16(s0 >> 208);
        i.protoFee = uint16(s0 >> 224);
        i.paused = (s0 >> 240) & 0xff != 0;
        uint256 s1 = uint256(h.extsload(bytes32(base + 1)));
        i.quote = address(uint160(s1));
        i.lamPpm = uint32(s1 >> 160);
        uint256 a = uint256(h.extsload(bytes32(base + SRC)));
        i.leader.kind = uint8(a);
        i.leader.coinIs0 = (a >> 8) & 0xff != 0;
        i.leader.target = address(uint160(a >> 48));
        i.leader.v4Id = h.extsload(bytes32(base + SRC + 1));
        uint256 c = uint256(h.extsload(bytes32(base + SRC + 2)));
        i.leader.kind2 = uint8(c >> 24);
        i.leader.xIs0 = (c >> 32) & 0xff != 0;
        i.leader.target2 = address(uint160(c >> 40));
        i.leader.v4Id2 = h.extsload(bytes32(base + SRC + 3));
        i.jarX = uint256(h.extsload(bytes32(base + JAR_X)));
        i.jarY = uint256(h.extsload(bytes32(base + JAR_Y)));
    }
}
