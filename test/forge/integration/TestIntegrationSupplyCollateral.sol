// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import "test/forge/BlueBase.t.sol";

contract IntegrationSupplyCollateralTest is BlueBaseTest {
    function testSupplyCollateralUnknownMarket(Market memory marketFuzz) public {
        vm.assume(neq(marketFuzz, market));

        vm.expectRevert(bytes(Errors.MARKET_NOT_CREATED));
        blue.supply(marketFuzz, 1, address(this), hex"");
    }

    function testSupplyCollateralZeroAmount() public {
        vm.expectRevert(bytes(Errors.ZERO_AMOUNT));
        blue.supplyCollateral(market, 0, address(this), hex"");
    }

    function testSupplyCollateralOnBehalfZeroAddress() public {
        vm.expectRevert(bytes(Errors.ZERO_ADDRESS));
        blue.supplyCollateral(market, 1, address(0), hex"");
    }

    function testSupplyCollateral(uint256 amount) public {
        amount = bound(amount, 1, MAX_TEST_AMOUNT);

        collateralAsset.setBalance(address(this), amount);

        vm.expectEmit(true, true, true, true, address(blue));
        emit Events.SupplyCollateral(id, address(this), address(this), amount);
        blue.supplyCollateral(market, amount, address(this), hex"");

        assertEq(blue.collateral(id, address(this)), amount, "collateral balance");
        assertEq(collateralAsset.balanceOf(address(this)), 0, "lender balance");
        assertEq(collateralAsset.balanceOf(address(blue)), amount, "blue balance");
    }

    function testSupplyCollateralOnBehalf(uint256 amount, address onBehalf) public {
        vm.assume(onBehalf != address(blue) && onBehalf != address(0));
        amount = bound(amount, 1, MAX_TEST_AMOUNT);

        collateralAsset.setBalance(address(this), amount);

        vm.expectEmit(true, true, true, true, address(blue));
        emit Events.SupplyCollateral(id, address(this), onBehalf, amount);
        blue.supplyCollateral(market, amount, onBehalf, hex"");

        assertEq(blue.collateral(id, onBehalf), amount, "collateral balance");
        assertEq(collateralAsset.balanceOf(onBehalf), 0, "lender balance");
        assertEq(collateralAsset.balanceOf(address(blue)), amount, "blue balance");
    }
}
