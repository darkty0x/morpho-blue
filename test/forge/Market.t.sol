// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "src/Market.sol";
import {ERC20Mock as ERC20} from "src/mocks/ERC20Mock.sol";
import {OracleMock as Oracle} from "src/mocks/OracleMock.sol";

contract MarketTest is Test {
    using MathLib for uint;

    address private constant borrower = address(1234);
    address private constant liquidator = address(5678);

    Market private market;
    ERC20 private borrowableAsset;
    ERC20 private collateralAsset;
    Oracle private borrowableOracle;
    Oracle private collateralOracle;

    function setUp() public {
        borrowableAsset = new ERC20("borrowable", "B", 18);
        collateralAsset = new ERC20("collateral", "C", 18);
        borrowableOracle = new Oracle();
        collateralOracle = new Oracle();
        market = new Market(
            address(borrowableAsset),
            address(collateralAsset),
            address(borrowableOracle),
            address(collateralOracle)
        );

        // We set the price of the borrowable asset to zero so that borrowers
        // don't need to deposit any collateral.
        borrowableOracle.setPrice(0);
        collateralOracle.setPrice(1e18);

        borrowableAsset.approve(address(market), type(uint).max);
        collateralAsset.approve(address(market), type(uint).max);
        vm.startPrank(borrower);
        borrowableAsset.approve(address(market), type(uint).max);
        collateralAsset.approve(address(market), type(uint).max);
        vm.stopPrank();
    }

    // To move to a test utils file later.

    function networth(address user) internal view returns (uint) {
        uint collateralAssetValue = collateralAsset.balanceOf(user).wMul(collateralOracle.price());
        uint borrowableAssetValue = borrowableAsset.balanceOf(user).wMul(borrowableOracle.price());
        return collateralAssetValue + borrowableAssetValue;
    }

    function supplyBalance(uint bucket, address user) internal view returns (uint) {
        uint supplyShares = market.supplyShare(user, bucket);
        uint totalShares = market.totalSupplyShares(bucket);
        uint totalSupply = market.totalSupply(bucket);
        return supplyShares.wMul(totalSupply).wDiv(totalShares);
    }

    function borrowBalance(uint bucket, address user) internal view returns (uint) {
        uint borrowerShares = market.borrowShare(user, bucket);
        uint totalShares = market.totalBorrowShares(bucket);
        uint totalBorrow = market.totalBorrow(bucket);
        return borrowerShares.wMul(totalBorrow).wDiv(totalShares);
    }

    // Invariants

    function invariantParams() public {
        assertEq(market.borrowableAsset(), address(borrowableAsset));
        assertEq(market.collateralAsset(), address(collateralAsset));
        assertEq(market.borrowableOracle(), address(borrowableOracle));
        assertEq(market.collateralOracle(), address(collateralOracle));
    }

    function invariantLiquidity() public {
        for (uint bucket; bucket < N; bucket++) {
            assertLe(market.totalBorrow(bucket), market.totalSupply(bucket));
        }
    }

    // Tests

    function testDeposit(uint amount, uint bucket) public {
        amount = bound(amount, 1, 2 ** 64);
        vm.assume(bucket < N);

        borrowableAsset.setBalance(address(this), amount);
        market.modifyDeposit(int(amount), bucket);

        assertEq(market.supplyShare(address(this), bucket), 1e18);
        assertEq(borrowableAsset.balanceOf(address(this)), 0);
        assertEq(borrowableAsset.balanceOf(address(market)), amount);
    }

    function testBorrow(uint amountLent, uint amountBorrowed, uint bucket) public {
        amountLent = bound(amountLent, 0, 2 ** 64);
        amountBorrowed = bound(amountBorrowed, 0, 2 ** 64);
        vm.assume(bucket < N);

        borrowableAsset.setBalance(address(this), amountLent);
        market.modifyDeposit(int(amountLent), bucket);

        if (amountBorrowed == 0) {
            market.modifyBorrow(int(amountBorrowed), bucket);
            return;
        }

        if (amountBorrowed > amountLent) {
            vm.prank(borrower);
            vm.expectRevert("not enough liquidity");
            market.modifyBorrow(int(amountBorrowed), bucket);
            return;
        }

        vm.prank(borrower);
        market.modifyBorrow(int(amountBorrowed), bucket);

        assertEq(market.borrowShare(borrower, bucket), 1e18);
        assertEq(borrowableAsset.balanceOf(borrower), amountBorrowed);
        assertEq(borrowableAsset.balanceOf(address(market)), amountLent - amountBorrowed);
    }

    function testWithdraw(uint amountLent, uint amountWithdrawn, uint amountBorrowed, uint bucket) public {
        amountLent = bound(amountLent, 1, 2 ** 64);
        vm.assume(bucket < N);
        vm.assume(amountLent >= amountBorrowed);
        vm.assume(int(amountWithdrawn) >= 0);

        borrowableAsset.setBalance(address(this), amountLent);
        market.modifyDeposit(int(amountLent), bucket);

        vm.prank(borrower);
        market.modifyBorrow(int(amountBorrowed), bucket);

        if (amountWithdrawn > amountLent - amountBorrowed) {
            if (amountWithdrawn > amountLent) {
                vm.expectRevert();
            } else {
                vm.expectRevert("not enough liquidity");
            }
            market.modifyDeposit(-int(amountWithdrawn), bucket);
            return;
        }

        market.modifyDeposit(-int(amountWithdrawn), bucket);

        assertApproxEqAbs(
            market.supplyShare(address(this), bucket), (amountLent - amountWithdrawn) * 1e18 / amountLent, 1e3
        );
        assertEq(borrowableAsset.balanceOf(address(this)), amountWithdrawn);
        assertEq(borrowableAsset.balanceOf(address(market)), amountLent - amountBorrowed - amountWithdrawn);
    }

    function testCollateralRequirements(
        uint amountCollateral,
        uint amountBorrowed,
        uint priceCollateral,
        uint priceBorrowable,
        uint bucket
    ) public {
        amountBorrowed = bound(amountBorrowed, 0, 2 ** 64);
        priceBorrowable = bound(priceBorrowable, 0, 2 ** 64);
        amountCollateral = bound(amountCollateral, 0, 2 ** 64);
        priceCollateral = bound(priceCollateral, 0, 2 ** 64);
        vm.assume(bucket < N);

        borrowableOracle.setPrice(priceBorrowable);
        collateralOracle.setPrice(priceCollateral);

        borrowableAsset.setBalance(address(this), amountBorrowed);
        collateralAsset.setBalance(borrower, amountCollateral);

        market.modifyDeposit(int(amountBorrowed), bucket);

        vm.prank(borrower);
        market.modifyCollateral(int(amountCollateral), bucket);

        uint collateralValue = amountCollateral.wMul(priceCollateral);
        uint borrowValue = amountBorrowed.wMul(priceBorrowable);
        if (borrowValue == 0 || (collateralValue > 0 && borrowValue <= collateralValue.wMul(bucketToLLTV(bucket)))) {
            vm.prank(borrower);
            market.modifyBorrow(int(amountBorrowed), bucket);
        } else {
            vm.prank(borrower);
            vm.expectRevert("not enough collateral");
            market.modifyBorrow(int(amountBorrowed), bucket);
        }
    }

    function testRepay(uint amountLent, uint amountBorrowed, uint amountRepaid, uint bucket) public {
        amountLent = bound(amountLent, 1, 2 ** 64);
        amountBorrowed = bound(amountBorrowed, 1, amountLent);
        amountRepaid = bound(amountRepaid, 0, amountBorrowed);
        vm.assume(bucket < N);

        borrowableAsset.setBalance(address(this), amountLent);
        market.modifyDeposit(int(amountLent), bucket);

        vm.startPrank(borrower);
        market.modifyBorrow(int(amountBorrowed), bucket);
        market.modifyBorrow(-int(amountRepaid), bucket);
        vm.stopPrank();

        assertApproxEqAbs(
            market.borrowShare(borrower, bucket), (amountBorrowed - amountRepaid) * 1e18 / amountBorrowed, 1e3
        );
        assertEq(borrowableAsset.balanceOf(borrower), amountBorrowed - amountRepaid);
        assertEq(borrowableAsset.balanceOf(address(market)), amountLent - amountBorrowed + amountRepaid);
    }

    function testDepositCollateral(uint amount, uint bucket) public {
        vm.assume(bucket < N);
        vm.assume(int(amount) >= 0);

        collateralAsset.setBalance(address(this), amount);
        market.modifyCollateral(int(amount), bucket);

        assertEq(market.collateral(address(this), bucket), amount);
        assertEq(collateralAsset.balanceOf(address(this)), 0);
        assertEq(collateralAsset.balanceOf(address(market)), amount);
    }

    function testWithdrawCollateral(uint amountDeposited, uint amountWithdrawn, uint bucket) public {
        vm.assume(bucket < N);

        vm.assume(amountDeposited >= amountWithdrawn);
        vm.assume(int(amountDeposited) >= 0);

        collateralAsset.setBalance(address(this), amountDeposited);
        market.modifyCollateral(int(amountDeposited), bucket);
        market.modifyCollateral(-int(amountWithdrawn), bucket);

        assertEq(market.collateral(address(this), bucket), amountDeposited - amountWithdrawn);
        assertEq(collateralAsset.balanceOf(address(this)), amountWithdrawn);
        assertEq(collateralAsset.balanceOf(address(market)), amountDeposited - amountWithdrawn);
    }

    function testLiquidate(uint bucket, uint amountLent) public {
        borrowableOracle.setPrice(1e18);
        amountLent = bound(amountLent, 1000, 2 ** 64);
        vm.assume(bucket < N);

        uint amountCollateral = amountLent;
        uint lLTV = bucketToLLTV(bucket);
        uint borrowingPower = amountCollateral.wMul(lLTV);
        uint amountBorrowed = borrowingPower.wMul(0.8e18);
        uint maxCollat = amountCollateral.wMul(lLTV);

        borrowableAsset.setBalance(address(this), amountLent);
        collateralAsset.setBalance(borrower, amountCollateral);
        borrowableAsset.setBalance(liquidator, amountBorrowed);

        // Lend
        borrowableAsset.approve(address(market), type(uint).max);
        market.modifyDeposit(int(amountLent), bucket);

        // Borrow
        vm.startPrank(borrower);
        collateralAsset.approve(address(market), type(uint).max);
        market.modifyCollateral(int(amountCollateral), bucket);
        market.modifyBorrow(int(amountBorrowed), bucket);
        vm.stopPrank();

        // Price change
        borrowableOracle.setPrice(2e18);

        uint liquidatorNetWorthBefore = networth(liquidator);

        // Liquidate
        Market.Liquidation[] memory liquidationData = new Market.Liquidation[](1);
        liquidationData[0] = Market.Liquidation(bucket, borrower, maxCollat);
        vm.startPrank(liquidator);
        borrowableAsset.approve(address(market), type(uint).max);
        (int sumCollat, int sumBorrow) = market.batchLiquidate(liquidationData);
        vm.stopPrank();

        uint liquidatorNetWorthAfter = networth(liquidator);

        assertGt(liquidatorNetWorthAfter, liquidatorNetWorthBefore, "liquidator's networth");
        assertLt(sumCollat, 0, "collateral seized");
        assertLt(sumBorrow, 0, "borrow repaid");
        assertApproxEqAbs(
            int(borrowBalance(bucket, borrower)), int(amountBorrowed) + sumBorrow, 100, "collateral balance borrower"
        );
        assertApproxEqAbs(
            int(market.collateral(borrower, bucket)),
            int(amountCollateral) + sumCollat,
            100,
            "collateral balance borrower"
        );
    }

    function testTwoUsersSupply(uint firstAmount, uint secondAmount, uint bucket) public {
        vm.assume(bucket < N);
        firstAmount = bound(firstAmount, 1, 2 ** 64);
        secondAmount = bound(secondAmount, 0, 2 ** 64);

        borrowableAsset.setBalance(address(this), firstAmount);
        market.modifyDeposit(int(firstAmount), bucket);

        borrowableAsset.setBalance(borrower, secondAmount);
        vm.prank(borrower);
        market.modifyDeposit(int(secondAmount), bucket);

        assertEq(market.supplyShare(address(this), bucket), 1e18);
        assertEq(market.supplyShare(borrower, bucket), secondAmount * 1e18 / firstAmount);
    }

    function testModifyDepositUnknownBucket(uint bucket) public {
        vm.assume(bucket > N);
        vm.expectRevert("unknown bucket");
        market.modifyDeposit(1, bucket);
    }

    function testModifyBorrowUnknownBucket(uint bucket) public {
        vm.assume(bucket > N);
        vm.expectRevert("unknown bucket");
        market.modifyBorrow(1, bucket);
    }

    function testModifyCollateralUnknownBucket(uint bucket) public {
        vm.assume(bucket > N);
        vm.expectRevert("unknown bucket");
        market.modifyCollateral(1, bucket);
    }
}
