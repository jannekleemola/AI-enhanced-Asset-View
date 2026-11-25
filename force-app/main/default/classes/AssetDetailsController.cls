/**
 * Server side for the assetDetails LWC: warranty status from Asset Warranty
 * records and AI-generated Asset Insights from a Flex prompt template.
 */
public with sharing class AssetDetailsController {

    public class WarrantySummary {
        @AuraEnabled public String status;      // In Warranty | Out of Warranty | No Warranty
        @AuraEnabled public String termName;
        @AuraEnabled public String termCode;
        @AuraEnabled public Date endDate;
        @AuraEnabled public String detail;
        @AuraEnabled public String coveredAssetName; // set when the warranty sits on a component
    }

    public class LastService {
        @AuraEnabled public Id workOrderId;
        @AuraEnabled public String workOrderNumber;
        @AuraEnabled public Datetime serviceDate;
        @AuraEnabled public String workType;
    }

    /**
     * Most recent completed/closed work order on the asset or one of its components.
     * @param excludeRecordId the current record (never counted as "last service")
     * @param asOfDate YYYY-MM-DD; jobs after this day are ignored (blank = today)
     */
    @AuraEnabled(cacheable=true)
    public static LastService getLastService(Id assetId, Id excludeRecordId, String asOfDate) {
        if (assetId == null) return null;
        Datetime cutoff = Datetime.newInstance(AssetInsightsPromptData.resolveAsOf(asOfDate).addDays(1), Time.newInstance(0, 0, 0, 0));
        for (WorkOrder wo : [
            SELECT Id, WorkOrderNumber, EndDate, LastModifiedDate, WorkType.Name, StatusCategory
            FROM WorkOrder
            WHERE (AssetId = :assetId OR Asset.ParentId = :assetId OR Asset.RootAssetId = :assetId)
              AND StatusCategory IN ('Completed', 'Closed')
              AND Id != :excludeRecordId
            ORDER BY EndDate DESC NULLS LAST, LastModifiedDate DESC LIMIT 20
        ]) {
            Datetime d = wo.EndDate != null ? wo.EndDate : wo.LastModifiedDate;
            if (d >= cutoff) continue;
            LastService ls = new LastService();
            ls.workOrderId = wo.Id;
            ls.workOrderNumber = wo.WorkOrderNumber;
            ls.serviceDate = d;
            ls.workType = wo.WorkType?.Name;
            return ls;
        }
        return null;
    }

    /**
     * @param termCodes comma-separated WarrantyTerm.Code values to consider (blank = all)
     * @param asOfDate  YYYY-MM-DD used as "today" (blank = today)
     */
    @AuraEnabled(cacheable=true)
    public static WarrantySummary getWarrantySummary(Id assetId, String termCodes, String asOfDate) {
        WarrantySummary s = new WarrantySummary();
        if (assetId == null) { s.status = 'No Warranty'; return s; }
        Date asOf = AssetInsightsPromptData.resolveAsOf(asOfDate);

        Set<String> codes = new Set<String>();
        if (String.isNotBlank(termCodes)) {
            for (String c : termCodes.split(',')) if (String.isNotBlank(c)) codes.add(c.trim());
        }
        List<AssetWarranty> ws = [
            SELECT AssetId, Asset.Name, StartDate, EndDate, WarrantyTerm.WarrantyTermName, WarrantyTerm.Code
            FROM AssetWarranty
            WHERE AssetId = :assetId OR Asset.ParentId = :assetId OR Asset.RootAssetId = :assetId
            ORDER BY EndDate DESC NULLS FIRST
        ];
        AssetWarranty activeW;
        AssetWarranty latestW;
        for (AssetWarranty w : ws) {
            if (!codes.isEmpty() && !codes.contains(w.WarrantyTerm?.Code)) continue;
            if (latestW == null) latestW = w;
            Boolean active = (w.StartDate == null || w.StartDate <= asOf) && (w.EndDate == null || w.EndDate >= asOf);
            if (active && activeW == null) activeW = w;
        }
        AssetWarranty pick = activeW != null ? activeW : latestW;
        if (pick == null) { s.status = 'No Warranty'; return s; }
        s.status = activeW != null ? 'In Warranty' : 'Out of Warranty';
        s.termName = pick.WarrantyTerm?.WarrantyTermName;
        s.termCode = pick.WarrantyTerm?.Code;
        if (pick.AssetId != assetId) s.coveredAssetName = pick.Asset?.Name;
        s.endDate = pick.EndDate;
        s.detail = (activeW != null ? 'Until ' : 'Expired ') + AssetInsightsPromptData.fmt(pick.EndDate);
        return s;
    }

    // ------------------------------------------------------------------
    // Spare-part selection list (probability from completed jobs on the same model)
    // ------------------------------------------------------------------
    public static final Integer MIN_SAMPLE = 5;

    public class PartSuggestion {
        @AuraEnabled public Id productId;
        @AuraEnabled public String name;
        @AuraEnabled public String code;
        @AuraEnabled public String groupName;
        @AuraEnabled public String category;     // Likely fix | Also check | Care & upsell | Labour
        @AuraEnabled public Integer probability; // 0..100
        @AuraEnabled public String reason;
        @AuraEnabled public Decimal quantity;
        @AuraEnabled public Decimal unitPrice;
        @AuraEnabled public String currencyCode;
        @AuraEnabled public String coverage;
        @AuraEnabled public Boolean onJob = false;
        @AuraEnabled public Boolean isLabor = false;
        @AuraEnabled public Id productRequiredId;
        @AuraEnabled public Decimal plannedQty;
    }

    public class PartSuggestions {
        @AuraEnabled public String faultCode;
        @AuraEnabled public Integer sampleSize;
        @AuraEnabled public List<PartSuggestion> parts = new List<PartSuggestion>();
        @AuraEnabled public String message;
    }

    @AuraEnabled
    public static PartSuggestions getPartSuggestions(Id workOrderId, String faultCodeField, Decimal minProbability,
                                                     String laborProductCode, Decimal laborQuantity, String priceCurrency) {
        PartSuggestions out = new PartSuggestions();
        if (workOrderId == null || workOrderId.getSobjectType() != WorkOrder.SObjectType) {
            out.message = 'Part selection is available on work orders.';
            return out;
        }
        Decimal minPct = minProbability == null ? 8 : minProbability;
        String faultField = null;
        if (String.isNotBlank(faultCodeField)) {
            Schema.SObjectField f = Schema.SObjectType.WorkOrder.fields.getMap().get(faultCodeField.trim().toLowerCase());
            if (f != null) faultField = f.getDescribe().getName();
        }
        Boolean multiCurrency = UserInfo.isMultiCurrencyOrganization();
        WorkOrder wo = (WorkOrder) Database.query('SELECT Id, AssetId, Asset.Product2Id'
            + (faultField != null ? ', ' + faultField : '') + (multiCurrency ? ', CurrencyIsoCode' : '')
            + ' FROM WorkOrder WHERE Id = :workOrderId')[0];
        String currencyIso = !multiCurrency ? null
            : String.isNotBlank(priceCurrency) ? priceCurrency.trim().toUpperCase() : (String) wo.get('CurrencyIsoCode');
        Id modelId = wo.AssetId == null ? null : wo.Asset.Product2Id;

        Set<Id> onJob = new Set<Id>();
        Map<Id, ProductRequired> required = new Map<Id, ProductRequired>();
        for (ProductRequired pr : [SELECT Id, Product2Id, Product2.Name, Product2.ProductCode, Product2.Family, QuantityRequired
                                   FROM ProductRequired WHERE ParentRecordId = :workOrderId ORDER BY CreatedDate]) {
            onJob.add(pr.Product2Id);
            if (!required.containsKey(pr.Product2Id)) required.put(pr.Product2Id, pr);
        }

        if (modelId != null) {
            String fc = faultField == null ? '' : norm(String.valueOf(wo.get(faultField)));
            out.faultCode = String.isBlank(fc) ? null : fc;
            // history stats
            Map<String, Integer> jobsByCode = new Map<String, Integer>();
            Integer jobsTotal = 0;
            Map<Id, Integer> usedForCode = new Map<Id, Integer>();
            Map<Id, Integer> usedTotal = new Map<Id, Integer>();
            String fcExpr = faultField == null ? null : faultField;
            String jobsSoql = 'SELECT ' + (fcExpr != null ? fcExpr + ' fc, ' : '') + 'COUNT(Id) n FROM WorkOrder'
                + ' WHERE Asset.Product2Id = :modelId AND Status IN (\'Completed\',\'Closed\')'
                + (fcExpr != null ? ' GROUP BY ' + fcExpr : '');
            for (AggregateResult a : Database.query(jobsSoql)) {
                Integer n = (Integer) a.get('n');
                jobsTotal += n;
                String k = fcExpr != null ? norm(String.valueOf(a.get('fc'))) : '';
                jobsByCode.put(k, (jobsByCode.containsKey(k) ? jobsByCode.get(k) : 0) + n);
            }
            String usedSoql = 'SELECT ' + (fcExpr != null ? 'WorkOrder.' + fcExpr + ' fc, ' : '') + 'Product2Id p, COUNT_DISTINCT(WorkOrderId) n'
                + ' FROM ProductConsumed WHERE WorkOrder.Asset.Product2Id = :modelId AND WorkOrder.Status IN (\'Completed\',\'Closed\')'
                + ' GROUP BY ' + (fcExpr != null ? 'WorkOrder.' + fcExpr + ', ' : '') + 'Product2Id';
            for (AggregateResult a : Database.query(usedSoql)) {
                Id pid = (Id) a.get('p'); Integer n = (Integer) a.get('n');
                usedTotal.put(pid, (usedTotal.containsKey(pid) ? usedTotal.get(pid) : 0) + n);
                if (fcExpr != null && norm(String.valueOf(a.get('fc'))) == fc) usedForCode.put(pid, n);
            }
            Integer sample = jobsByCode.containsKey(fc) ? jobsByCode.get(fc) : 0;
            Boolean codeKnown = String.isNotBlank(fc) && sample >= MIN_SAMPLE;
            out.sampleSize = codeKnown ? sample : jobsTotal;

            // campaign coverage: open campaign on the asset naming the part code
            List<ProductServiceCampaign> pscs = new List<ProductServiceCampaign>();
            for (ProductServiceCampaignItem i : [SELECT ProductServiceCampaign.ProductServiceCampaignName, ProductServiceCampaign.Description
                                                 FROM ProductServiceCampaignItem
                                                 WHERE AssetId = :wo.AssetId AND Status NOT IN ('Completed','Canceled')]) {
                pscs.add(i.ProductServiceCampaign);
            }

            List<ProductRelatedComponent> bom = [
                SELECT ChildProductId, ChildProduct.Name, ChildProduct.ProductCode, ChildProduct.Family,
                       ProductComponentGroup.Name, Quantity
                FROM ProductRelatedComponent WHERE ParentProductId = :modelId AND ChildProductId != null];
            Set<Id> pids = new Set<Id>();
            for (ProductRelatedComponent c : bom) pids.add(c.ChildProductId);
            Map<Id, PricebookEntry> price = prices(pids, currencyIso);

            for (ProductRelatedComponent c : bom) {
                Integer used = codeKnown ? (usedForCode.containsKey(c.ChildProductId) ? usedForCode.get(c.ChildProductId) : 0)
                                         : (usedTotal.containsKey(c.ChildProductId) ? usedTotal.get(c.ChildProductId) : 0);
                Integer outOf = codeKnown ? sample : jobsTotal;
                Decimal prob = outOf == 0 ? 0 : (Decimal) used / outOf;
                String cat;
                if (c.ChildProduct.Family == 'Consumables') cat = prob >= 0.15 ? 'Care & upsell' : null;
                else if (prob >= 0.5) cat = 'Likely fix';
                else if (prob * 100 >= minPct) cat = 'Also check';
                if (cat == null) continue;
                PartSuggestion x = new PartSuggestion();
                x.productId = c.ChildProductId; x.name = c.ChildProduct.Name; x.code = c.ChildProduct.ProductCode;
                x.groupName = c.ProductComponentGroup?.Name; x.category = cat;
                x.probability = (Integer) Math.round(prob * 100);
                x.reason = 'Used in ' + used + ' of ' + outOf + (codeKnown ? ' ' + fc : '') + ' repairs on this model';
                x.quantity = c.Quantity == null ? 1 : c.Quantity;
                x.onJob = onJob.contains(x.productId);
                if (price.containsKey(x.productId)) { x.unitPrice = price.get(x.productId).UnitPrice; x.currencyCode = (String) price.get(x.productId).get('CurrencyIsoCode'); }
                for (ProductServiceCampaign psc : pscs) {
                    String txt = psc.ProductServiceCampaignName + ' ' + psc.Description;
                    if (x.code != null && txt.contains(x.code)) x.coverage = 'Free under ' + psc.ProductServiceCampaignName.substringBefore(' ');
                }
                out.parts.add(x);
            }
            out.parts.sort(new ByCategoryThenProbability());
        } else {
            out.message = 'Link an asset with a product to get part suggestions.';
        }

        if (String.isNotBlank(laborProductCode)) {
            List<Product2> labor = [SELECT Id, Name, ProductCode FROM Product2 WHERE ProductCode = :laborProductCode.trim() AND IsActive = true LIMIT 1];
            if (!labor.isEmpty()) {
                PartSuggestion l = new PartSuggestion();
                Decimal hrs = laborQuantity == null ? 1 : laborQuantity;
                l.productId = labor[0].Id; l.name = labor[0].Name;
                l.code = labor[0].ProductCode; l.category = 'Labour'; l.quantity = hrs; l.isLabor = true;
                l.reason = 'Service labour for the visit';
                l.onJob = onJob.contains(l.productId);
                Map<Id, PricebookEntry> lp = prices(new Set<Id>{ l.productId }, currencyIso);
                if (lp.containsKey(l.productId)) { l.unitPrice = lp.get(l.productId).UnitPrice; l.currencyCode = (String) lp.get(l.productId).get('CurrencyIsoCode'); }
                out.parts.add(l);
            }
        }
        // other Products Required already on the job, plus planned quantities
        Set<Id> listed = new Set<Id>();
        for (PartSuggestion x : out.parts) listed.add(x.productId);
        List<PartSuggestion> others = new List<PartSuggestion>();
        Set<Id> otherIds = new Set<Id>();
        for (ProductRequired pr : required.values()) {
            if (listed.contains(pr.Product2Id)) continue;
            PartSuggestion o = new PartSuggestion();
            o.productId = pr.Product2Id; o.name = pr.Product2.Name; o.code = pr.Product2.ProductCode;
            o.groupName = pr.Product2.Family; o.category = 'Other on job'; o.onJob = true;
            o.quantity = pr.QuantityRequired; o.reason = 'Added to the work order';
            others.add(o); otherIds.add(o.productId);
        }
        Map<Id, PricebookEntry> otherPrices = prices(otherIds, currencyIso);
        for (PartSuggestion o : others) {
            if (otherPrices.containsKey(o.productId)) { o.unitPrice = otherPrices.get(o.productId).UnitPrice; o.currencyCode = (String) otherPrices.get(o.productId).get('CurrencyIsoCode'); }
            out.parts.add(o);
        }
        for (PartSuggestion x : out.parts) {
            if (required.containsKey(x.productId)) {
                x.productRequiredId = required.get(x.productId).Id;
                x.plannedQty = required.get(x.productId).QuantityRequired;
            }
        }
        return out;
    }

    /** Adds products with explicit quantities (productId -> quantity); skips products already on the job. */
    @AuraEnabled
    public static Integer addProductsRequiredWithQuantities(Id workOrderId, Map<String, Decimal> quantities) {
        if (workOrderId == null || quantities == null || quantities.isEmpty()) return 0;
        Set<Id> ids = new Set<Id>();
        for (String k : quantities.keySet()) ids.add((Id) k);
        Set<Id> existing = new Set<Id>();
        for (ProductRequired pr : [SELECT Product2Id FROM ProductRequired WHERE ParentRecordId = :workOrderId AND Product2Id IN :ids]) existing.add(pr.Product2Id);
        List<ProductRequired> ins = new List<ProductRequired>();
        for (Id p : ids) {
            if (existing.contains(p)) continue;
            Decimal q = quantities.get(String.valueOf(p));
            if (q == null || q <= 0) q = 1;
            ins.add(new ProductRequired(ParentRecordId = workOrderId, Product2Id = p, QuantityRequired = q, QuantityUnitOfMeasure = 'Each'));
        }
        insert ins;
        return ins.size();
    }

    /** Sets the required quantity of a product on the job. */
    @AuraEnabled
    public static void updateProductRequiredQuantity(Id workOrderId, Id productId, Decimal quantity) {
        if (quantity == null || quantity <= 0) throw new AuraHandledException('Quantity must be greater than 0.');
        List<ProductRequired> prs = [SELECT Id FROM ProductRequired WHERE ParentRecordId = :workOrderId AND Product2Id = :productId ORDER BY CreatedDate];
        if (prs.isEmpty()) return;
        prs[0].QuantityRequired = quantity;
        update prs[0];
        if (prs.size() > 1) {
            List<ProductRequired> dupes = new List<ProductRequired>();
            for (Integer i = 1; i < prs.size(); i++) dupes.add(prs[i]);
            delete dupes;
        }
    }

    /** Removes a product from the job (all its Products Required lines). */
    @AuraEnabled
    public static void removeProductRequired(Id workOrderId, Id productId) {
        delete [SELECT Id FROM ProductRequired WHERE ParentRecordId = :workOrderId AND Product2Id = :productId];
    }

    /** Adds the selected products to the work order as Products Required (skips ones already there). */
    @AuraEnabled
    public static Integer addProductsRequired(Id workOrderId, List<Id> productIds, Id laborProductId, Decimal laborQuantity) {
        if (workOrderId == null || productIds == null || productIds.isEmpty()) return 0;
        WorkOrder wo = [SELECT Asset.Product2Id FROM WorkOrder WHERE Id = :workOrderId];
        Map<Id, Decimal> qty = new Map<Id, Decimal>();
        if (wo.Asset?.Product2Id != null) {
            for (ProductRelatedComponent c : [SELECT ChildProductId, Quantity FROM ProductRelatedComponent
                                              WHERE ParentProductId = :wo.Asset.Product2Id AND ChildProductId IN :productIds]) {
                qty.put(c.ChildProductId, c.Quantity);
            }
        }
        Set<Id> existing = new Set<Id>();
        for (ProductRequired pr : [SELECT Product2Id FROM ProductRequired WHERE ParentRecordId = :workOrderId AND Product2Id IN :productIds]) existing.add(pr.Product2Id);
        List<ProductRequired> ins = new List<ProductRequired>();
        for (Id p : new Set<Id>(productIds)) {
            if (existing.contains(p)) continue;
            Decimal q = p == laborProductId ? (laborQuantity == null ? 1 : laborQuantity)
                                            : (qty.get(p) == null ? 1 : qty.get(p));
            ins.add(new ProductRequired(ParentRecordId = workOrderId, Product2Id = p, QuantityRequired = q, QuantityUnitOfMeasure = 'Each'));
        }
        insert ins;
        return ins.size();
    }

    private static Map<Id, PricebookEntry> prices(Set<Id> productIds, String currencyIso) {
        Map<Id, PricebookEntry> out = new Map<Id, PricebookEntry>();
        if (productIds.isEmpty()) return out;
        Boolean mc = UserInfo.isMultiCurrencyOrganization();
        String soql = 'SELECT Product2Id, UnitPrice' + (mc ? ', CurrencyIsoCode' : '')
            + ' FROM PricebookEntry WHERE Product2Id IN :productIds AND Pricebook2.IsStandard = true AND IsActive = true';
        for (PricebookEntry e : (List<PricebookEntry>) Database.query(soql)) {
            Boolean preferred = mc && currencyIso != null && (String) e.get('CurrencyIsoCode') == currencyIso;
            if (!out.containsKey(e.Product2Id) || preferred) out.put(e.Product2Id, e);
        }
        return out;
    }

    private static String norm(String fc) { return String.isBlank(fc) || fc == 'null' ? '' : fc.trim().toUpperCase(); }

    private static Integer catRank(String c) {
        return c == 'Likely fix' ? 0 : c == 'Also check' ? 1 : c == 'Care & upsell' ? 2 : 3;
    }

    public class ByCategoryThenProbability implements Comparator<PartSuggestion> {
        public Integer compare(PartSuggestion a, PartSuggestion b) {
            Integer r = catRank(a.category) - catRank(b.category);
            if (r != 0) return r;
            return b.probability - a.probability;
        }
    }

    /** Runs the Flex prompt template and returns the generated text. */
    @AuraEnabled
    public static String generateInsight(Id assetId, String templateApiName, String asOfDate, Id contextRecordId, String faultCodeField) {
        if (assetId == null || String.isBlank(templateApiName)) return null;
        try {
            ConnectApi.EinsteinPromptTemplateGenerationsInput input = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
            Map<String, ConnectApi.WrappedValue> params = new Map<String, ConnectApi.WrappedValue>();
            ConnectApi.WrappedValue assetVal = new ConnectApi.WrappedValue();
            assetVal.value = new Map<String, String>{ 'id' => assetId };
            params.put('Input:Asset', assetVal);
            ConnectApi.WrappedValue dateVal = new ConnectApi.WrappedValue();
            dateVal.value = String.isBlank(asOfDate) ? String.valueOf(Date.today()) : asOfDate;
            params.put('Input:AsOfDate', dateVal);
            ConnectApi.WrappedValue ctxVal = new ConnectApi.WrappedValue();
            ctxVal.value = AssetInsightsPromptData.buildFactSheet(assetId, asOfDate, contextRecordId, faultCodeField);
            params.put('Input:AssetContext', ctxVal);
            input.inputParams = params;
            input.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
            input.additionalConfig.applicationName = 'PromptBuilderPreview';
            input.isPreview = false;
            ConnectApi.EinsteinPromptTemplateGenerationsRepresentation res =
                ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(templateApiName, input);
            if (res.generations == null || res.generations.isEmpty()) return null;
            return res.generations[0].text == null ? null : res.generations[0].text.trim();
        } catch (Exception e) {
            throw new AuraHandledException('Asset insight could not be generated: ' + e.getMessage());
        }
    }
}