# AI-enhanced Asset View

A Salesforce Lightning Web Component (`assetDetails`) for Field Service record pages (Work Order, Case, Service Appointment, and so on). It shows the asset linked to the record, together with AI-generated insights and spare-part recommendations.

## Features
- **Asset summary**: name, serial number, status, warranty status, install date, last service, location, account and part number. Each field can be switched on or off in App Builder.
- **Warranty status** is read from Asset Warranty records on the asset *and its component assets*, optionally filtered by WarrantyTerm codes. The status is In / Out of / No Warranty, and the badge tooltip shows the end date.
- **Last Service** is the most recent completed or closed Work Order on the asset or its components. The date links to that Work Order.
- **Asset Insights**: one or more Einstein Prompt Builder (Flex) templates, shown as tabs, grounded by `AssetInsightsPromptData` with the asset, warranty, history and current Work Order.
- **Spare-parts selection**: part probabilities learned from completed jobs on the same product model (optionally per fault code), plus labour and consumables. Selected parts are added to Products Required with quantities, and their quantities can be edited or removed inline.
- Map modal (Work Order address), a Flow launcher in the Actions menu, and an optional copyable prompt block.
- An **As-of date** property lets demos pin "today" to a fixed date.

## Contents
| Path | What |
|---|---|
| `lwc/assetDetails` | The component |
| `classes/AssetDetailsController` | Warranty, last service, insights and parts API |
| `classes/AssetInsightsPromptData` | Grounding fact sheet for the prompts |
| `classes/AssetDetailsControllerTest` | Tests (`SeeAllData=true`) |
| `genAiPromptTemplates/` | `Asset_Insights`, `Asset_Spare_Parts_Recommendation` |

## Prerequisites
- Field Service (WorkOrder, ProductRequired, AssetWarranty / WarrantyTerm)
- Einstein generative AI / Prompt Builder enabled (for the insights)
- Salesforce CLI

## Deploy
```bash
sf project deploy start -o <your-org-alias> -d force-app \
  --test-level RunSpecifiedTests --tests AssetDetailsControllerTest
```
After deploying, activate the prompt templates in Prompt Builder. Then add **assetDetails** to a record page in Lightning App Builder.

## Key App Builder properties
| Property | Purpose |
|---|---|
| `assetLookupField` | Field on the host record holding the Asset (default `AssetId`) |
| `showSerialNumber`, `showStatus`, `showWarrantyStatus`, `showInstallDate`, `showLastService`, `showLocation`, `showAccount`, `showPartNumber` | Field toggles |
| `warrantyTermCodes` | Comma-separated WarrantyTerm.Code values that count for the status |
| `asOfDate` | `YYYY-MM-DD` treated as today |
| `insightTemplates` / `defaultInsightTemplate` | `ApiName:Label, ApiName:Label` tabs |
| `partsSelectionTemplate` | The tab that shows the parts picker |
| `faultCodeField`, `partsMinProbability`, `laborProductCode`, `laborQuantity`, `priceCurrency` | Parts prediction tuning |
| `showMapButton`, `map*Field` | Map from the record's address |
| `flowApiName`, `flowMenuLabel`, `flowInputVariableName` | Flow launched from the Actions menu |
