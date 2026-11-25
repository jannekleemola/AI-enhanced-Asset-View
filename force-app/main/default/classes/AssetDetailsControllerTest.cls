@IsTest(SeeAllData=true)
private class AssetDetailsControllerTest {
    @IsTest
    static void coversWarrantyAndGrounding() {
        Account acc = new Account(Name = 'Test Asset Insights');
        insert acc;
        Asset a = new Asset(Name = 'Test washer', AccountId = acc.Id, Status = 'Installed', InstallDate = Date.newInstance(2023, 11, 24));
        insert a;
        WarrantyTerm t = new WarrantyTerm(WarrantyTermName = 'Test 2y', WarrantyType = 'Standard', WarrantyDuration = 24, WarrantyUnitOfTime = 'Months',
            EffectiveStartDate = 'Install Date', PartsCovered = 100, PartsCoveredDuration = 24, PartsCoveredUnitOfTime = 'Months',
            Code = 'TEST-24');
        insert t;
        insert new AssetWarranty(AssetId = a.Id, WarrantyTermId = t.Id, StartDate = Date.newInstance(2023, 11, 12),
            EndDate = Date.newInstance(2025, 11, 11), WarrantyType = 'Standard', PartsCovered = 100);

        Test.startTest();
        AssetDetailsController.WarrantySummary s = AssetDetailsController.getWarrantySummary(a.Id, 'TEST-24', '2026-11-11');
        AssetDetailsController.WarrantySummary s2 = AssetDetailsController.getWarrantySummary(a.Id, '', '2024-01-01');
        AssetDetailsController.WarrantySummary s3 = AssetDetailsController.getWarrantySummary(a.Id, 'NOPE', null);
        String facts = AssetInsightsPromptData.buildFactSheet(a.Id, '2026-11-11');
        WorkOrder wo = new WorkOrder(AccountId = acc.Id, AssetId = a.Id, Subject = 'Test job');
        insert wo;
        String facts2 = AssetInsightsPromptData.buildFactSheet(a.Id, '2026-11-11', wo.Id, 'Fault_Code__c');
        try { AssetDetailsController.generateInsight(a.Id, 'Asset_Insights', '2026-11-11', wo.Id, null); } catch (Exception e) { /* ConnectApi unavailable in tests */ }
        Product2 part = new Product2(Name = 'Test part', ProductCode = 'TP-1', IsActive = true);
        Product2 lab = new Product2(Name = 'Test labour', ProductCode = 'TL-1', IsActive = true);
        insert new List<Product2>{ part, lab };
        AssetDetailsController.PartSuggestions ps = AssetDetailsController.getPartSuggestions(wo.Id, 'Subject', 8, 'TL-1', 1, 'SEK');
        Integer added = AssetDetailsController.addProductsRequired(wo.Id, new List<Id>{ part.Id, lab.Id }, lab.Id, 1);
        AssetDetailsController.updateProductRequiredQuantity(wo.Id, part.Id, 3);
        AssetDetailsController.PartSuggestions ps3 = AssetDetailsController.getPartSuggestions(wo.Id, null, 8, null, null, null);
        AssetDetailsController.removeProductRequired(wo.Id, part.Id);
        Product2 extra = new Product2(Name = 'Extra', ProductCode = 'EX-1', IsActive = true);
        insert extra;
        Integer added2 = AssetDetailsController.addProductsRequiredWithQuantities(wo.Id, new Map<String, Decimal>{ String.valueOf(extra.Id) => 2 });
        AssetDetailsController.PartSuggestions ps2 = AssetDetailsController.getPartSuggestions(acc.Id, null, null, null, null, null);
        WorkOrder done = new WorkOrder(AccountId = acc.Id, AssetId = a.Id, Subject = 'Past PM', Status = 'Closed',
            StartDate = Datetime.newInstance(2026, 10, 1, 9, 0, 0), EndDate = Datetime.newInstance(2026, 10, 1, 12, 0, 0));
        insert done;
        AssetDetailsController.LastService ls = AssetDetailsController.getLastService(a.Id, wo.Id, '2026-11-11');
        AssetDetailsController.LastService lsNone = AssetDetailsController.getLastService(a.Id, wo.Id, '2026-09-01');
        Test.stopTest();
        System.assertEquals(done.Id, ls.workOrderId);
        System.assertEquals(null, lsNone);

        System.assertEquals('Out of Warranty', s.status);
        System.assertEquals('In Warranty', s2.status);
        System.assertEquals('No Warranty', s3.status);
        System.assert(facts.contains('EXPIRED'));
        System.assert(facts2.contains('CURRENT WORK ORDER'));
        System.assertEquals(2, added);
        System.assertEquals(1, added2);
        System.assertEquals(2, [SELECT QuantityRequired FROM ProductRequired WHERE ParentRecordId = :wo.Id AND Product2Id = :extra.Id].QuantityRequired);
        System.assertEquals(0, [SELECT COUNT() FROM ProductRequired WHERE ParentRecordId = :wo.Id AND Product2Id = :part.Id]);
        System.assertNotEquals(null, ps2.message);
    }
}