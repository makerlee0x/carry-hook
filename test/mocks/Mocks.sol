// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory name_, string memory symbol_, uint8 dec_) ERC20(name_, symbol_) {
        _dec = dec_;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}


import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice An ERC-4626 vault (stand-in for Morpho) whose liquidity the test can cap and whose assets it can lose.
contract MockVault is ERC4626 {
    uint256 public liquid = type(uint256).max;

    constructor(IERC20 asset_) ERC20("Vault", "V") ERC4626(asset_) {}

    function setLiquid(uint256 l) external {
        liquid = l;
    }

    /// @dev A loss: `amt` of the vault's assets disappear.
    function lose(uint256 amt) external {
        IERC20(asset()).transfer(address(0xdead), amt);
    }

    function maxWithdraw(address owner) public view virtual override returns (uint256) {
        uint256 m = super.maxWithdraw(owner);
        return m < liquid ? m : liquid;
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 m = super.maxRedeem(owner);
        uint256 l = liquid == type(uint256).max ? m : convertToShares(liquid);
        return m < l ? m : l;
    }
}

/// @notice An ERC-4626 vault that, like Morpho Vault V2, reports 0 from every max* and does not check them.
contract MockVaultNoMax is ERC4626 {
    /// @dev What the vault can pay out now; a withdrawal or redemption above it reverts (a partly liquid V2).
    uint256 public liquid = type(uint256).max;

    constructor(IERC20 asset_) ERC20("Vault V2", "V2") ERC4626(asset_) {}

    function setLiquid(uint256 l) external {
        liquid = l;
    }

    function maxDeposit(address) public pure override returns (uint256) {
        return 0;
    }

    function maxMint(address) public pure override returns (uint256) {
        return 0;
    }

    function maxWithdraw(address) public pure override returns (uint256) {
        return 0;
    }

    function maxRedeem(address) public pure override returns (uint256) {
        return 0;
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        shares = previewDeposit(assets);
        _deposit(_msgSender(), receiver, assets, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
        require(assets <= liquid, "illiquid");
        shares = previewWithdraw(assets);
        _withdraw(_msgSender(), receiver, owner, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
        assets = previewRedeem(shares);
        require(assets <= liquid, "illiquid");
        _withdraw(_msgSender(), receiver, owner, assets, shares);
    }
}
