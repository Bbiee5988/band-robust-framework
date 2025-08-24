import { Clarinet, Tx, Chain, Account, types } from 'https://deno.land/x/clarinet@v1.5.4/index.ts';
import { assertEquals } from 'https://deno.land/std@0.170.0/testing/asserts.ts';

Clarinet.test({
    name: "Ensure band group creation works correctly",
    async fn(chain: Chain, accounts: Map<string, Account>) {
        const deployer = accounts.get('deployer')!;

        const createGroupBlock = chain.mineBlock([
            Tx.contractCall(
                'band-shared-financials', 
                'create-group', 
                [types.ascii('Rock Stars')],
                deployer.address
            )
        ]);

        assertEquals(createGroupBlock.height, 2);
        createGroupBlock.receipts[0].result.expectOk().expectUint(1);
    }
});

Clarinet.test({
    name: "Verify band member addition process",
    async fn(chain: Chain, accounts: Map<string, Account>) {
        const deployer = accounts.get('deployer')!;
        const wallet1 = accounts.get('wallet_1')!;

        const createGroupBlock = chain.mineBlock([
            Tx.contractCall(
                'band-shared-financials', 
                'create-group', 
                [types.ascii('Rock Stars')],
                deployer.address
            )
        ]);

        const addMemberBlock = chain.mineBlock([
            Tx.contractCall(
                'band-shared-financials', 
                'add-member', 
                [types.uint(1), types.principal(wallet1.address)],
                deployer.address
            )
        ]);

        addMemberBlock.receipts[0].result.expectOk().expectBool(true);
    }
});

Clarinet.test({
    name: "Test payment settlement between band members",
    async fn(chain: Chain, accounts: Map<string, Account>) {
        const deployer = accounts.get('deployer')!;
        const wallet1 = accounts.get('wallet_1')!;
        const wallet2 = accounts.get('wallet_2')!;

        const groupCreationBlock = chain.mineBlock([
            Tx.contractCall(
                'band-shared-financials', 
                'create-group', 
                [types.ascii('Rock Stars')],
                deployer.address
            )
        ]);

        const addMembersBlock = chain.mineBlock([
            Tx.contractCall(
                'band-shared-financials', 
                'add-member', 
                [types.uint(1), types.principal(wallet1.address)],
                deployer.address
            ),
            Tx.contractCall(
                'band-shared-financials', 
                'add-member', 
                [types.uint(1), types.principal(wallet2.address)],
                deployer.address
            )
        ]);

        // Simulate a payment settlement
        const settlementBlock = chain.mineBlock([
            Tx.contractCall(
                'band-shared-financials', 
                'settle-payment', 
                [types.uint(1), types.principal(wallet1.address), types.uint(500)],
                wallet2.address
            )
        ]);

        settlementBlock.receipts[0].result.expectOk().expectUint(1);
    }
});