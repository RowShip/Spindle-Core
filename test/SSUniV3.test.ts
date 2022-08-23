import { expect } from "chai";
import { BigNumber } from "bignumber.js";
import { ethers, network } from "hardhat";
import {
  IERC20,
  IUniswapV3Factory,
  IUniswapV3Pool,
  SwapTest,
  SSUniVault,
  SSUniFactory,
  EIP173Proxy,
} from "../typechain-types";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/dist/src/signer-with-address";


describe("SSUniVault", () => {
  // eslint-disable-next-line
  BigNumber.config({ EXPONENTIAL_AT: 999999, DECIMAL_PLACES: 40 });

  // returns the sqrt price as a 64x96
  function encodePriceSqrt(reserve1: string, reserve0: string) {
    return new BigNumber(reserve1)
      .div(reserve0)
      .sqrt()
      .multipliedBy(new BigNumber(2).pow(96))
      .integerValue(3)
      .toString();
  }

  function position(address: string, lowerTick: number, upperTick: number) {
    return ethers.utils.solidityKeccak256(
      ["address", "int24", "int24"],
      [address, lowerTick, upperTick]
    );
  }

  let uniswapFactory: IUniswapV3Factory;
  let uniswapPool: IUniswapV3Pool;

  let token0: IERC20;
  let token1: IERC20;
  let user0: SignerWithAddress;
  let user1: SignerWithAddress;
  let user2: SignerWithAddress;
  let swapTest: SwapTest;
  let sSUniVault: SSUniVault;
  let sSUniFactory: SSUniFactory;
  let gelato: SignerWithAddress;
  let uniswapPoolAddress: string;
  let implementationAddress: string;

  before(async function () {
    [user0, user1, user2, gelato] = await ethers.getSigners();

    const swapTestFactory = await ethers.getContractFactory("SwapTest");
    swapTest = (await swapTestFactory.deploy()) as SwapTest;
  });

  beforeEach(async function () {
    const uniswapV3Factory = await ethers.getContractFactory(
      "UniswapV3Factory"
    );
    const uniswapDeploy = await uniswapV3Factory.deploy();
    uniswapFactory = (await ethers.getContractAt(
      "IUniswapV3Factory",
      uniswapDeploy.address
    )) as IUniswapV3Factory;

    const mockERC20Factory = await ethers.getContractFactory("MockERC20");
    token0 = (await mockERC20Factory.deploy()) as IERC20;
    token1 = (await mockERC20Factory.deploy()) as IERC20;

    await token0.approve(
      swapTest.address,
      ethers.utils.parseEther("10000000000000")
    );
    await token1.approve(
      swapTest.address,
      ethers.utils.parseEther("10000000000000")
    );

    // Sort token0 & token1 so it follows the same order as Uniswap & the sSUniVaultFactory
    if (
      ethers.BigNumber.from(token0.address).gt(
        ethers.BigNumber.from(token1.address)
      )
    ) {
      const tmp = token0;
      token0 = token1;
      token1 = tmp;
    }

    await uniswapFactory.createPool(token0.address, token1.address, "3000");
    uniswapPoolAddress = await uniswapFactory.getPool(
      token0.address,
      token1.address,
      "3000"
    );
    uniswapPool = (await ethers.getContractAt(
      "IUniswapV3Pool",
      uniswapPoolAddress
    )) as IUniswapV3Pool;
    await uniswapPool.initialize(encodePriceSqrt("1", "1"));

    await uniswapPool.increaseObservationCardinalityNext("5");

    const sSUniVaultFactory = await ethers.getContractFactory("SSUniVault");
    const gUniImplementation = await sSUniVaultFactory.deploy(
      await gelato.getAddress()
    );

    implementationAddress = gUniImplementation.address;

    const sSUniFactoryFactory = await ethers.getContractFactory("SSUniFactory");

    sSUniFactory = (await sSUniFactoryFactory.deploy(
      uniswapFactory.address
    )) as SSUniFactory;

    await sSUniFactory.initialize(
      implementationAddress,
      await user0.getAddress()
    );

    const pool = await sSUniFactory.createManagedPool(
      token0.address,
      token1.address,
      3000,
      0,
      -887220,
      887220
    );

    const deployers = await sSUniFactory.getDeployers();
    const deployer = deployers[0];
    const pools = await sSUniFactory.getPools(deployer);
    expect(pools.length).to.equal(1);
    expect(pools[0]).to.equal(pool);

    sSUniVault = (await ethers.getContractAt("SSUniVault", pools[0])) as SSUniVault;
  });
  describe("Before liquidity deposited", function () {
    beforeEach(async function () {
      await token0.approve(
        sSUniVault.address,
        ethers.utils.parseEther("1000000")
      );
      await token1.approve(
        sSUniVault.address,
        ethers.utils.parseEther("1000000")
      );
    });
  })
});