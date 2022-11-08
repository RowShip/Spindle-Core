import { ethers } from "hardhat";
import { SpindleOracle } from "../typechain/SpindleOracle";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/dist/src/signer-with-address";

const ORACLE_ADDRESS = "0x0000000000f0021d219C5AE2Fd5b261966012Dd7";

async function readOracle(poolAddress : string) {
    const [deployer] = await ethers.getSigners();
    console.log(deployer.address);
    const oracle = (await ethers.getContractFactory("SpindleOracle")).attach(ORACLE_ADDRESS) as SpindleOracle;
    const IV = await oracle.callStatic.estimate24H(poolAddress)
    console.log(IV)
}

const UNI_ETH_030 = "0x1d42064Fc4Beb5F8aAF85F4617AE8b3b5B8Bd801";
const USDC_ETH_030 = "0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8";
const USDC_ETH_005 = "0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640";
const WBTC_ETH_005 = "0x4585FE77225b41b697C938B018E2Ac67Ac5a20c0";
const FEI_TRIBE_005 = "0x4Eb91340079712550055F648e0984655F3683107";
const DAI_USDC_001 = "0x5777d92f208679DB4b9778590Fa3CAB3aC9e2168";
const WETH_LOOKS_030 = "0x4b5Ab61593A2401B1075b90c04cBCDD3F87CE011";
const X2Y2_WETH_030 = "0x52cfA6bF6659175FcE27a23AbdEe798897Fe4c04";
const RAI_WETH_030 = "0x14DE8287AdC90f0f95Bf567C0707670de52e3813";


// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
readOracle(USDC_ETH_005).catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
