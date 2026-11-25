/**
 * Grounding for the Flex prompt template "Asset_Insights" (passed as its AssetContext input).
 * Builds a plain-text fact sheet for an Asset: product, attributes, warranty
 * coverage evaluated against an as-of date, service campaigns, open cases and
 * recent work orders.
 */
public with sharing class AssetInsightsPromptData {

    public static Date resolveAsOf(String asOfDate) {
        if (String.isNotBlank(asOfDate)) {
            try { return Date.valueOf(asOfDate.trim()); } catch (Exception e) { /* fall through */ }
        }
        return Date.today();
    }

    public static String fmt(Date d) {
        return d == null ? 'n/a' : Datetime.newInstance(d.year(), d.month(), d.day()).format('d MMM yyyy');
    }

    public static String buildFactSheet(Id assetId, String asOfDate) {
        return buildFactSheet(assetId, asOfDate, null, null);
    }

    /**
     * @param contextRecordId record the card sits on (a Work Order adds a CURRENT WORK ORDER section)
     * @param faultCodeField  optional WorkOrder field API name holding a fault/symptom code; used to
     *                        group fleet history (jobs and parts per fault code)
     */
    public static String buildFactSheet(Id assetId, String asOfDate, Id contextRecordId, String faultCodeField) {
        if (assetId == null) return 'No asset provided.';
        String faultField = validWorkOrderField(faultCodeField);
        Date asOf = resolveAsOf(asOfDate);
        List<String> l = new List<String>();

        Asset a = [
            SELECT Name, SerialNumber, Status, InstallDate, PurchaseDate, Description, Product2Id,
                   Product2.Name, Product2.ProductCode, Product2.Family,
                   Account.Name, Location.Name
            FROM Asset WHERE Id = :assetId
        ];
        l.add('AS-OF DATE: ' + fmt(asOf));
        l.add('');
        l.add('ASSET');
        l.add('- Name: ' + a.Name);
        l.add('- Product: ' + a.Product2?.Name + ' (code ' + a.Product2?.ProductCode + ', family ' + a.Product2?.Family + ')');
        l.add('- Serial number: ' + a.SerialNumber);
        l.add('- Status: ' + a.Status);
        l.add('- Purchased: ' + fmt(a.PurchaseDate) + ', installed: ' + fmt(a.InstallDate));
        if (a.InstallDate != null) {
            l.add('- Age: ' + a.InstallDate.monthsBetween(asOf) + ' months');
        }
        l.add('- Customer: ' + a.Account?.Name + ', location: ' + a.Location?.Name);
        if (String.isNotBlank(a.Description)) {
            l.add('- Notes: ' + a.Description.left(1500));
        }

        List<AssetAttribute> attrs = [
            SELECT AttributeDefinition.Label, AttributeName, AttributeValue
            FROM AssetAttribute WHERE AssetId = :assetId LIMIT 30
        ];
        if (!attrs.isEmpty()) {
            l.add('');
            l.add('ATTRIBUTES');
            for (AssetAttribute at : attrs) {
                String label = at.AttributeDefinition?.Label != null ? at.AttributeDefinition.Label : at.AttributeName;
                l.add('- ' + label + ': ' + at.AttributeValue);
            }
        }

        l.add('');
        l.add('WARRANTY COVERAGE (evaluated on the as-of date)');
        List<AssetWarranty> ws = [
            SELECT WarrantyType, StartDate, EndDate, PartsCovered, LaborCovered, ExpensesCovered, Exclusions,
                   WarrantyTerm.WarrantyTermName, WarrantyTerm.Code
            FROM AssetWarranty WHERE AssetId = :assetId ORDER BY EndDate
        ];
        if (ws.isEmpty()) l.add('- No warranties recorded.');
        for (AssetWarranty w : ws) {
            Boolean active = (w.StartDate == null || w.StartDate <= asOf) && (w.EndDate == null || w.EndDate >= asOf);
            l.add('- ' + w.WarrantyTerm?.WarrantyTermName + ' [' + w.WarrantyTerm?.Code + ']: '
                + (active ? 'ACTIVE' : 'EXPIRED') + ', ' + fmt(w.StartDate) + ' to ' + fmt(w.EndDate)
                + '; parts ' + pct(w.PartsCovered) + ', labour ' + pct(w.LaborCovered) + ', expenses ' + pct(w.ExpensesCovered)
                + (String.isNotBlank(w.Exclusions) ? '; notes: ' + w.Exclusions.left(300) : ''));
        }

        List<ProductServiceCampaignItem> pscs = [
            SELECT ProductServiceCampaign.ProductServiceCampaignName, ProductServiceCampaign.Type,
                   ProductServiceCampaign.Description, ProductServiceCampaign.EndDate, Status
            FROM ProductServiceCampaignItem WHERE AssetId = :assetId LIMIT 10
        ];
        if (!pscs.isEmpty()) {
            l.add('');
            l.add('SERVICE CAMPAIGNS');
            for (ProductServiceCampaignItem p : pscs) {
                l.add('- ' + p.ProductServiceCampaign?.ProductServiceCampaignName + ' (' + p.ProductServiceCampaign?.Type
                    + ', item status ' + p.Status + ', ends ' + fmt(p.ProductServiceCampaign?.EndDate) + '): '
                    + String.valueOf(p.ProductServiceCampaign?.Description).left(300));
            }
        }

        List<Case> cases = [
            SELECT CaseNumber, Subject, Status, Priority, CreatedDate
            FROM Case WHERE AssetId = :assetId AND IsClosed = false ORDER BY CreatedDate DESC LIMIT 5
        ];
        l.add('');
        l.add('OPEN CASES');
        if (cases.isEmpty()) l.add('- None.');
        for (Case c : cases) {
            l.add('- ' + c.CaseNumber + ' (' + c.Status + ', ' + c.Priority + ', opened ' + fmt(c.CreatedDate.date()) + '): ' + c.Subject);
        }

        List<WorkOrder> wos = [
            SELECT WorkOrderNumber, Subject, Status, CreatedDate, Description
            FROM WorkOrder WHERE AssetId = :assetId ORDER BY CreatedDate DESC LIMIT 6
        ];
        l.add('');
        l.add('RECENT WORK ORDERS');
        if (wos.isEmpty()) l.add('- None.');
        for (WorkOrder w : wos) {
            l.add('- ' + w.WorkOrderNumber + ' (' + w.Status + ', created ' + fmt(w.CreatedDate.date()) + '): ' + w.Subject);
        }
        Set<Id> partIds = new Set<Id>();
        safeAdd(l, 'CURRENT WORK ORDER', currentWorkOrder(contextRecordId, faultField));
        safeAdd(l, 'SERVICE BOM (parts for this model)', serviceBom(a.Product2Id, partIds));
        safeAdd(l, 'FLEET SERVICE HISTORY (completed jobs on the same model)', fleetHistory(a.Product2Id, faultField, partIds));
        safeAdd(l, 'STOCK ON HAND (relevant parts)', stock(partIds));
        return String.join(l, '\n');
    }

    // ---------- optional sections (each fails soft) ----------

    private static void safeAdd(List<String> l, String title, List<String> lines) {
        if (lines == null || lines.isEmpty()) return;
        l.add('');
        l.add(title);
        l.addAll(lines);
    }

    private static String validWorkOrderField(String f) {
        if (String.isBlank(f)) return null;
        Schema.SObjectField fld = Schema.SObjectType.WorkOrder.fields.getMap().get(f.trim().toLowerCase());
        return fld == null ? null : fld.getDescribe().getName();
    }

    private static List<String> currentWorkOrder(Id recordId, String faultField) {
        List<String> l = new List<String>();
        if (recordId == null || recordId.getSobjectType() != WorkOrder.SObjectType) return l;
        try {
            String soql = 'SELECT WorkOrderNumber, Subject, Status, Priority, Description, WorkType.Name, CreatedDate'
                + (faultField != null ? ', ' + faultField : '')
                + ', (SELECT Subject, Status FROM WorkOrderLineItems ORDER BY LineItemNumber LIMIT 15)'
                + ', (SELECT Product2.Name, Product2.ProductCode, QuantityRequired FROM ProductsRequired LIMIT 15)'
                + ' FROM WorkOrder WHERE Id = :recordId';
            WorkOrder w = (WorkOrder) Database.query(soql)[0];
            l.add('- ' + w.WorkOrderNumber + ' (' + w.Status + ', ' + w.Priority + ', work type ' + w.WorkType?.Name + '): ' + w.Subject);
            if (faultField != null && w.get(faultField) != null) l.add('- Fault code: ' + w.get(faultField));
            if (String.isNotBlank(w.Description)) l.add('- Description: ' + w.Description.left(1200));
            for (WorkOrderLineItem li : w.WorkOrderLineItems) l.add('- Task: ' + li.Subject + ' (' + li.Status + ')');
            for (ProductRequired pr : w.ProductsRequired) {
                l.add('- Part already planned: ' + pr.Product2?.Name + ' (' + pr.Product2?.ProductCode + ') x' + pr.QuantityRequired);
            }
        } catch (Exception e) { l.clear(); }
        return l;
    }

    private static List<String> serviceBom(Id modelId, Set<Id> partIds) {
        List<String> l = new List<String>();
        if (modelId == null) return l;
        try {
            for (ProductRelatedComponent c : [
                SELECT ProductComponentGroup.Name, ChildProductId, ChildProduct.Name, ChildProduct.ProductCode, Quantity
                FROM ProductRelatedComponent WHERE ParentProductId = :modelId AND ChildProductId != null
                ORDER BY ProductComponentGroup.Name LIMIT 60]) {
                partIds.add(c.ChildProductId);
                l.add('- [' + c.ProductComponentGroup?.Name + '] ' + c.ChildProduct.Name + ' (' + c.ChildProduct.ProductCode + ')');
            }
        } catch (Exception e) { l.clear(); }
        return l;
    }

    private static List<String> fleetHistory(Id modelId, String faultField, Set<Id> partIds) {
        List<String> l = new List<String>();
        if (modelId == null) return l;
        try {
            Integer total = [SELECT COUNT() FROM WorkOrder WHERE Asset.Product2Id = :modelId AND Status = 'Completed'];
            if (total == 0) return l;
            l.add('- Completed jobs on this model: ' + total);
            if (faultField != null) {
                Map<String, Integer> jobs = new Map<String, Integer>();
                for (AggregateResult r : Database.query('SELECT ' + faultField + ' fc, COUNT(Id) n FROM WorkOrder'
                        + ' WHERE Asset.Product2Id = :modelId AND Status = \'Completed\' AND ' + faultField + ' != null'
                        + ' GROUP BY ' + faultField + ' ORDER BY COUNT(Id) DESC LIMIT 12')) {
                    jobs.put(String.valueOf(r.get('fc')), (Integer) r.get('n'));
                }
                if (!jobs.isEmpty()) {
                    List<String> parts = new List<String>();
                    for (String k : jobs.keySet()) parts.add(k + ' ' + jobs.get(k));
                    l.add('- Jobs by fault code: ' + String.join(parts, ', '));
                }
                for (AggregateResult r : Database.query('SELECT WorkOrder.' + faultField + ' fc, Product2Id pid, Product2.Name pn,'
                        + ' Product2.ProductCode pc, COUNT_DISTINCT(WorkOrderId) n FROM ProductConsumed'
                        + ' WHERE WorkOrder.Asset.Product2Id = :modelId AND WorkOrder.Status = \'Completed\''
                        + ' GROUP BY WorkOrder.' + faultField + ', Product2Id, Product2.Name, Product2.ProductCode'
                        + ' ORDER BY COUNT_DISTINCT(WorkOrderId) DESC LIMIT 25')) {
                    String fc = String.valueOf(r.get('fc'));
                    Integer n = (Integer) r.get('n');
                    Integer outOf = jobs.containsKey(fc) ? jobs.get(fc) : null;
                    partIds.add((Id) r.get('pid'));
                    l.add('- Fault ' + fc + ': ' + r.get('pn') + ' (' + r.get('pc') + ') used in ' + n
                        + (outOf != null ? ' of ' + outOf + ' jobs (' + Math.round(100.0 * n / outOf) + '%)' : ' jobs'));
                }
            } else {
                for (AggregateResult r : [
                    SELECT Product2Id pid, Product2.Name pn, Product2.ProductCode pc, COUNT_DISTINCT(WorkOrderId) n
                    FROM ProductConsumed WHERE WorkOrder.Asset.Product2Id = :modelId AND WorkOrder.Status = 'Completed'
                    GROUP BY Product2Id, Product2.Name, Product2.ProductCode ORDER BY COUNT_DISTINCT(WorkOrderId) DESC LIMIT 15]) {
                    partIds.add((Id) r.get('pid'));
                    l.add('- ' + r.get('pn') + ' (' + r.get('pc') + ') used in ' + r.get('n') + ' of ' + total + ' jobs');
                }
            }
            List<String> recent = new List<String>();
            for (WorkOrder w : [SELECT WorkOrderNumber, Subject FROM WorkOrder
                                WHERE Asset.Product2Id = :modelId AND Status = 'Completed'
                                ORDER BY CreatedDate DESC LIMIT 8]) {
                recent.add(w.Subject);
            }
            if (!recent.isEmpty()) l.add('- Recent job subjects: ' + String.join(recent, ' | '));
        } catch (Exception e) { l.clear(); }
        return l;
    }

    private static List<String> stock(Set<Id> partIds) {
        List<String> l = new List<String>();
        if (partIds.isEmpty()) return l;
        try {
            for (ProductItem pi : [
                SELECT Product2.Name, Product2.ProductCode, Location.Name, QuantityOnHand
                FROM ProductItem WHERE Product2Id IN :partIds AND QuantityOnHand > 0
                ORDER BY Product2.Name, QuantityOnHand DESC LIMIT 40]) {
                l.add('- ' + pi.Product2.Name + ' (' + pi.Product2.ProductCode + '): ' + pi.QuantityOnHand.setScale(0)
                    + ' at ' + pi.Location?.Name);
            }
        } catch (Exception e) { l.clear(); }
        return l;
    }

    private static String pct(Decimal d) {
        return d == null ? 'not covered' : d.setScale(0) + '%';
    }
}