// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { LiquidityAmounts } from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import { Actions } from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

/// @notice Manages Uniswap v4 pool creation and liquidity minting for PNPT/FNBT reward tokens.
contract RewardTokensManager is Ownable {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    //  Constants
    /// @notice 0.3% fee tier — standard Uniswap fee for moderate-volatility pairs
    uint24 public constant FEE_TIER = 3000;
    /// @notice Tick spacing paired with the 0.3% fee tier
    int24 public constant TICK_SPACING = 60;
    /// @notice No hooks for this assignment
    address public constant HOOKS = address(0);

    //  Immutables
    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    IERC20 public immutable pnpToken;
    IERC20 public immutable fnbToken;
    /// @notice Permit2 address retrieved from the PositionManager at deploy time
    address public immutable permit2Address;

    //  State
    /// @notice Tracks which poolIds have been created through this contract
    mapping(bytes32 => bool) public createdPools;

    PoolKey private _poolKey;
    bool private _poolCreated;

    // Events
    /// @notice Emitted when a new Uniswap v4 pool is initialised
    event PoolCreated(
        bytes32 indexed poolId,
        address currency0,
        address currency1,
        uint24 fee,
        int24 tickSpacing,
        address hooks,
        uint160 sqrtPriceX96
    );

    /// @notice Emitted when liquidity is successfully minted into the pool
    event LiquidityMinted(
        bytes32 indexed poolId,
        uint256 positionId,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    );

    // Errors
    error PoolNotCreated();
    error TickRangeDoesNotCoverAssignmentPrice();
    error ZeroLiquidity();

    // Constructor initialises the contract with references to the PoolManager, PositionManager, and token contracts. It also retrieves the Permit2 address from the PositionManager for later use in liquidity operations.
    constructor(
        address _poolManager,
        address _positionManager,
        address _pnpToken,
        address _fnbToken
    ) Ownable(msg.sender) {
        poolManager = IPoolManager(_poolManager);
        positionManager = IPositionManager(_positionManager);
        pnpToken = IERC20(_pnpToken);
        fnbToken = IERC20(_fnbToken);
        // Try both PERMIT2() and permit2() since different versions use different casing
        (bool ok, bytes memory data) = _positionManager.staticcall(abi.encodeWithSignature("permit2()"));
        if (!ok || data.length != 32) {
            (ok, data) = _positionManager.staticcall(abi.encodeWithSignature("PERMIT2()"));
        }
        permit2Address = ok && data.length == 32 ? abi.decode(data, (address)) : address(0);
    }

    //  View helpers

    /// @notice Returns the canonical (sorted) currency pair for the pool
    function getCanonicalCurrencies() public view returns (address currency0, address currency1) {
        currency0 = Currency.unwrap(_poolKey.currency0);
        currency1 = Currency.unwrap(_poolKey.currency1);
    }

    /// @notice Returns the poolId for the current pool key
    function getPoolId() public view returns (bytes32) {
        return PoolId.unwrap(_poolKey.toId());
    }

    /// @notice Derives the target tick from the assignment price: 1 FNBT = 10 PNPT.
    /// @dev    price = currency0/currency1. tick = ln(price)/ln(1.0001)
    ///         If PNPT is currency0: price = 0.01/0.10 = 0.1  => tick = -23027
    ///         If FNBT is currency0: price = 0.10/0.01 = 10   => tick =  23027
    function getTargetTick() public view returns (int24) {
        address pnp = address(pnpToken);
        address fnb = address(fnbToken);
        if (pnp < fnb) {
            // PNPT is currency0, FNBT is currency1: price = 0.1 => tick ≈ -23027
            return -23027;
        } else {
            // FNBT is currency0, PNPT is currency1: price = 10 => tick ≈ 23027
            return 23027;
        }
    }

    //  Pool creation

    /// @notice Creates and initialises a Uniswap v4 pool for PNPT/FNBT.
    /// @dev    onlyOwner restricts pool creation to the deployer to prevent
    ///         unauthorised pools being registered in this contract's state.
    /// @param sqrtPriceX96 Initial sqrt price in Q64.96 format
    /// @return poolId The bytes32 pool identifier
    function createPool(uint160 sqrtPriceX96) external onlyOwner returns (bytes32 poolId) {
        address pnp = address(pnpToken);
        address fnb = address(fnbToken);

        // Sort tokens canonically — Uniswap requires currency0 < currency1
        (address token0, address token1) = pnp < fnb ? (pnp, fnb) : (fnb, pnp);

        _poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: FEE_TIER,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOKS)
        });

        poolId = PoolId.unwrap(_poolKey.toId());

        // Initialise the pool at the given starting sqrt price
        poolManager.initialize(_poolKey, sqrtPriceX96);

        _poolCreated = true;
        createdPools[poolId] = true;

        emit PoolCreated(poolId, token0, token1, FEE_TIER, TICK_SPACING, HOOKS, sqrtPriceX96);
    }

    //  Liquidity minting

    /// @notice Mints a concentrated liquidity position in the PNPT/FNBT pool.
    /// @param tickLower      Lower bound of the tick range (aligned to TICK_SPACING)
    /// @param tickUpper      Upper bound of the tick range (aligned to TICK_SPACING)
    /// @param amount0Desired Max amount of currency0 to contribute
    /// @param amount1Desired Max amount of currency1 to contribute
    function mintLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) external returns (uint256 positionId, bytes32 poolId) {
        // 1) Validate user inputs and tick constraints
        require(amount0Desired > 0 || amount1Desired > 0, "Zero amounts");
        require(tickLower < tickUpper, "Invalid tick range");
        require(tickLower % TICK_SPACING == 0 && tickUpper % TICK_SPACING == 0, "Ticks not aligned");

        // 2) Ensure the chosen range includes the target tick for the assignment price
        //    1 FNBT = 10 PNPT => tick ≈ ±23027 depending on sort order
        int24 targetTick = getTargetTick();
        if (targetTick < tickLower || targetTick >= tickUpper) {
            revert TickRangeDoesNotCoverAssignmentPrice();
        }

        // 3) Resolve and verify the liquidity pool exists
        if (!_poolCreated) revert PoolNotCreated();
        poolId = PoolId.unwrap(_poolKey.toId());

        // 4) Compute liquidity from desired token amounts at the current pool sqrt price
        //    sqrtPriceX96 is fetched live from PoolManager state
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(PoolId.wrap(poolId));
        uint160 sqrtRatioAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            amount0Desired,
            amount1Desired
        );
        if (liquidity == 0) revert ZeroLiquidity();

        // 5) Pull desired token amounts from caller into this contract
        //    Caller must have approved this contract on both tokens first
        address cur0 = Currency.unwrap(_poolKey.currency0);
        address cur1 = Currency.unwrap(_poolKey.currency1);
        if (amount0Desired > 0) IERC20(cur0).transferFrom(msg.sender, address(this), amount0Desired);
        if (amount1Desired > 0) IERC20(cur1).transferFrom(msg.sender, address(this), amount1Desired);

        // 6) Approve Permit2 so PositionManager can settle pool deltas
        //    Uniswap v4 uses Permit2 for all token transfers during liquidity operations
        if (amount0Desired > 0) IERC20(cur0).approve(permit2Address, amount0Desired);
        if (amount1Desired > 0) IERC20(cur1).approve(permit2Address, amount1Desired);

        // 7) Prepare PositionManager mint actions and execute modifyLiquidities
        //    MINT_POSITION action encodes the full position parameters
        //    SETTLE_PAIR action tells the PositionManager to pull tokens via Permit2
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            _poolKey,
            tickLower,
            tickUpper,
            liquidity,
            amount0Desired, // max amount of currency0 to spend
            amount1Desired, // max amount of currency1 to spend
            msg.sender, // recipient of the NFT position
            bytes("") // no hook data
        );
        params[1] = abi.encode(_poolKey.currency0, _poolKey.currency1);

        uint256 nextId = positionManager.nextTokenId();

        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);

        // 8) Verify mint succeeded — nextTokenId increments by 1 per mint
        positionId = nextId;
        uint128 mintedLiquidity = positionManager.getPositionLiquidity(positionId);
        if (mintedLiquidity == 0) revert ZeroLiquidity();

        // 9) Return any unspent token dust to caller and emit assignment event
        uint256 dust0 = IERC20(cur0).balanceOf(address(this));
        uint256 dust1 = IERC20(cur1).balanceOf(address(this));
        if (dust0 > 0) IERC20(cur0).transfer(msg.sender, dust0);
        if (dust1 > 0) IERC20(cur1).transfer(msg.sender, dust1);

        emit LiquidityMinted(poolId, positionId, msg.sender, tickLower, tickUpper, mintedLiquidity);
    }
}
