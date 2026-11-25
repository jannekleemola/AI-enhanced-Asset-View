import { LightningElement, api, wire, track } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getWarrantySummary from '@salesforce/apex/AssetDetailsController.getWarrantySummary';
import getLastService from '@salesforce/apex/AssetDetailsController.getLastService';
import generateInsight from '@salesforce/apex/AssetDetailsController.generateInsight';
import getPartSuggestions from '@salesforce/apex/AssetDetailsController.getPartSuggestions';
import addProductsRequiredWithQuantities from '@salesforce/apex/AssetDetailsController.addProductsRequiredWithQuantities';
import updateProductRequiredQuantity from '@salesforce/apex/AssetDetailsController.updateProductRequiredQuantity';
import removeProductRequired from '@salesforce/apex/AssetDetailsController.removeProductRequired';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { RefreshEvent } from 'lightning/refresh';

const MONTH = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];

const BASE_ASSET_FIELDS = [
    'Asset.Name',
    'Asset.SerialNumber',
    'Asset.Status',
    'Asset.InstallDate',
    'Asset.LifecycleEndDate',
    'Asset.LocationId',
    'Asset.Location.Name',
    'Asset.AccountId',
    'Asset.Account.Name',
    'Asset.StockKeepingUnit',
];

export default class AssetDetails extends NavigationMixin(LightningElement) {

    // ----- Page Builder configurable properties -----
    @api recordId;
    @api objectApiName;
    @api cardTitle = 'Asset Details';

    /** API name of the field on this record that holds the Asset lookup */
    @api assetLookupField = 'AssetId';

    // Field visibility toggles
    @api showSerialNumber = false;
    @api showStatus = false;
    @api showWarrantyStatus = false;
    @api showInstallDate = false;
    @api showLastService = false;
    @api showLocation = false;
    @api showAccount = false;
    @api showPartNumber = false;
    @api showEinsteinInsights = false;
    /** Heading of the insights panel (e.g. Appliance Insights). */
    @api insightsTitle = 'Asset Insights';

    /** API name of an Asset field whose value is used as the insights text (fallback) */
    @api insightsFieldApiName;

    /** Flex prompt template (API name) that generates the Asset Insights text. Blank = no AI. */
    @api insightsPromptTemplate = 'Asset_Insights';

    /**
     * Optional list of prompt templates the user can switch between in the insights panel.
     * Format: "ApiName:Label, ApiName:Label". Overrides insightsPromptTemplate when set.
     */
    @api insightTemplates;
    @api defaultInsightTemplate;

    /** Optional WorkOrder field holding a fault code; groups fleet history in the AI grounding */
    @api faultCodeField;

    /** Template (API name) whose tab also shows a selectable parts list (work orders only) */
    @api partsSelectionTemplate;
    /** Minimum probability (%) for "Also check" parts */
    @api partsMinProbability = 8;
    /** ProductCode of a service/labour product offered with the parts */
    @api laborProductCode;
    /** Labour quantity (hours) */
    @api laborQuantity = 1;
    /** Preferred price currency (ISO code, e.g. SEK). Blank = the work order's currency */
    @api priceCurrency;

    /** Comma-separated WarrantyTerm.Code values that drive the Warranty Status (blank = all) */
    @api warrantyTermCodes;

    /** YYYY-MM-DD treated as "today" for warranty status and insights (blank = today) */
    @api asOfDate;
    // Max height (px) of the scrollable predictions area; 0 = no limit
    @api insightsMaxHeight = 420;

    // Prompt template
    @api showPromptTemplate = false;
    @api promptTemplateLabel = 'AI Prompt Template';
    /** Template text supporting {assetName} {serialNumber} {status} {location} {installDate} {account} */
    @api promptTemplate = '';

    // Map
    @api showMapButton = false;
    /** API name of a single parent field containing a full address string (legacy / optional) */
    @api mapAddressField;
    /**
     * API names of the parent record's compound address parts. Defaults to the
     * standard WorkOrder address fields so the map matches the standard Address card.
     */
    @api mapStreetField = 'Street';
    @api mapCityField = 'City';
    @api mapStateField = 'State';
    @api mapPostalCodeField = 'PostalCode';
    @api mapCountryField = 'Country';

    /** API name of a Flow to run from the Actions menu. Leave blank to hide the Flow action. */
    @api flowApiName;
    @api flowMenuLabel = 'Run Flow';
    @api flowInputVariableName = 'recordId';

    // ----- Internal state -----
    @track assetId;
    @track assetData;
    @track parentData;
    @track parentError;
    @track assetError;
    @track parentResolved = false;
    @track assetResolved = false;
    @track showFlow = false;
    @track showMap = false;
    warranty;
    lastService;
    insightResults = {};   // template api name -> generated text
    loadingTemplate;       // template currently generating
    activeTemplate;
    aiError;
    _aiAssetId;

    // parts selection
    partsData;
    partsLoading = false;
    partsSaving = false;
    selectedParts = new Set();
    draftQty = {};        // productId -> qty for rows not yet on the job
    pendingQty = {};      // productId -> qty being saved for rows on the job
    busyParts = new Set();
    _qtyTimers = {};

    // collapse state of the Asset Insights panel (remembered per record)
    insightsCollapsed = false;

    // ---- Stage 1: get Asset ID (and address) from parent record ----
    @wire(getRecord, { recordId: '$recordId', fields: '$parentFields' })
    wiredParent({ data, error }) {
        if (data) {
            const field = `${this.objectApiName}.${this.assetLookupField}`;
            this.assetId = getFieldValue(data, field) || null;
            this.parentData = data;
            this.parentError = null;
            this.parentResolved = true;
        } else if (error) {
            this.parentError = error;
            this.assetId = null;
            this.parentData = null;
            this.parentResolved = true;
        }
    }

    // ---- Stage 2: fetch Asset record once we have the ID ----
    @wire(getRecord, { recordId: '$assetId', fields: '$assetFields' })
    wiredAsset({ data, error }) {
        if (data) {
            this.assetData = data;
            this.assetError = null;
            this.assetResolved = true;
            if (this.showEinsteinInsights && this._aiAssetId !== this.assetId) {
                this._aiAssetId = this.assetId;
                this.insightResults = {};
                this.loadInsight(this.currentTemplate);
                if (this.showPartsList) this.loadParts(true);
            }
        } else if (error) {
            this.assetError = error;
            this.assetData = null;
            this.assetResolved = true;
        }
    }

    // ---- Warranty status from Asset Warranty records ----
    @wire(getWarrantySummary, { assetId: '$assetId', termCodes: '$warrantyCodesParam', asOfDate: '$asOfDateParam' })
    wiredWarranty({ data, error }) {
        if (data) this.warranty = data;
        else if (error) this.warranty = undefined;
    }

    // ---- Last service: latest completed/closed WO on the asset or its components ----
    @wire(getLastService, { assetId: '$assetId', excludeRecordId: '$recordId', asOfDate: '$asOfDateParam' })
    wiredLastService({ data, error }) {
        if (data !== undefined) this.lastService = data;
        else if (error) this.lastService = undefined;
    }

    get lastServiceId() {
        return this.lastService && this.lastService.workOrderId;
    }

    get lastServiceDate() {
        const raw = this.lastService && this.lastService.serviceDate;
        if (!raw) return '—';
        const d = new Date(raw);
        return `${MONTH[d.getMonth()]} ${d.getDate()}, ${d.getFullYear()}`;
    }

    get lastServiceSub() {
        const ls = this.lastService;
        if (!ls) return '';
        return [ls.workType, ls.workOrderNumber].filter(Boolean).join(' · ');
    }

    get lastServiceTitle() {
        return this.lastService ? `Open work order ${this.lastService.workOrderNumber}` : '';
    }

    handleLastServiceClick() {
        if (this.lastServiceId) {
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: { recordId: this.lastServiceId, actionName: 'view' }
            });
        }
    }

    // Wired Apex is not called while a reactive param is undefined, so default blanks to ''
    get insightScrollStyle() {
        const h = parseInt(this.insightsMaxHeight, 10);
        return h > 0 ? `max-height:${h}px` : '';
    }

    get warrantyCodesParam() {
        return this.warrantyTermCodes || '';
    }

    get asOfDateParam() {
        return this.asOfDate || '';
    }

    // ---- AI insight from the Flex prompt template ----
    get templateList() {
        const out = [];
        (this.insightTemplates || '').split(',').forEach((entry) => {
            const [api, label] = entry.split(':').map((x) => (x || '').trim());
            if (api) out.push({ api, label: label || api });
        });
        if (!out.length && this.insightsPromptTemplate) {
            out.push({ api: this.insightsPromptTemplate, label: this.panelTitle });
        }
        return out;
    }

    get currentTemplate() {
        const list = this.templateList;
        if (this.activeTemplate && list.some((t) => t.api === this.activeTemplate)) return this.activeTemplate;
        const def = (this.defaultInsightTemplate || '').trim();
        if (def && list.some((t) => t.api === def)) return def;
        return list.length ? list[0].api : undefined;
    }

    get templateTabs() {
        const current = this.currentTemplate;
        return this.templateList.map((t) => ({
            ...t,
            className: t.api === current ? 'insight-tab insight-tab--active' : 'insight-tab',
            ariaSelected: t.api === current ? 'true' : 'false'
        }));
    }

    get hasTemplateTabs() {
        return this.templateList.length > 1;
    }

    get hasAiTemplate() {
        return this.templateList.length > 0;
    }

    get panelTitle() {
        return (this.insightsTitle || '').trim() || 'Asset Insights';
    }

    get insightTitle() {
        if (this.hasTemplateTabs) return this.panelTitle;
        const list = this.templateList;
        return list.length ? list[0].label : this.panelTitle;
    }

    get collapseButtonTitle() {
        return 'Collapse ' + this.panelTitle;
    }

    get aiLoading() {
        return !!this.loadingTemplate && this.loadingTemplate === this.currentTemplate;
    }

    loadInsight(templateApiName) {
        if (!templateApiName || !this.assetId) return;
        this.loadingTemplate = templateApiName;
        this.aiError = undefined;
        generateInsight({
            assetId: this.assetId,
            templateApiName,
            asOfDate: this.asOfDate,
            contextRecordId: this.recordId,
            faultCodeField: this.faultCodeField
        })
            .then((text) => {
                this.insightResults = { ...this.insightResults, [templateApiName]: text || '' };
            })
            .catch((e) => {
                this.aiError = (e && e.body && e.body.message) || 'Insight unavailable';
                this.insightResults = { ...this.insightResults, [templateApiName]: null };
                // eslint-disable-next-line no-console
                console.warn('Asset insight failed', templateApiName, this.aiError);
            })
            .finally(() => {
                if (this.loadingTemplate === templateApiName) this.loadingTemplate = undefined;
            });
    }

    handleTemplateSelect(event) {
        const api = event.currentTarget.dataset.api;
        this.activeTemplate = api;
        if (!(api in this.insightResults) && this.loadingTemplate !== api) this.loadInsight(api);
        if (this.showPartsList && !this.partsData && !this.partsLoading) this.loadParts(true);
    }

    handleRefreshInsight() {
        this.loadInsight(this.currentTemplate);
        if (this.showPartsList) this.loadParts(false);
    }

    // ---- Parts selection list ----
    get showPartsList() {
        return !!this.partsSelectionTemplate
            && this.objectApiName === 'WorkOrder'
            && this.currentTemplate === this.partsSelectionTemplate;
    }

    loadParts(preselect) {
        if (!this.recordId) return;
        this.partsLoading = true;
        getPartSuggestions({
            workOrderId: this.recordId,
            faultCodeField: this.faultCodeField,
            minProbability: Number(this.partsMinProbability),
            laborProductCode: this.laborProductCode,
            laborQuantity: Number(this.laborQuantity) || 1,
            priceCurrency: this.priceCurrency
        })
            .then((data) => {
                this.partsData = data;
                this.pendingQty = {};
                const sel = new Set();
                if (preselect) {
                    (data.parts || []).forEach((p) => {
                        if (!p.onJob && (p.category === 'Likely fix' || p.isLabor)) sel.add(p.productId);
                    });
                } else {
                    this.selectedParts.forEach((id) => {
                        if ((data.parts || []).some((p) => p.productId === id && !p.onJob)) sel.add(id);
                    });
                }
                this.selectedParts = sel;
            })
            .catch((e) => {
                this.partsData = { parts: [], message: (e && e.body && e.body.message) || 'Could not load parts' };
            })
            .finally(() => { this.partsLoading = false; });
    }

    get partGroups() {
        const order = ['Likely fix', 'Labour', 'Also check', 'Care & upsell', 'Other on job'];
        const hints = {
            'Likely fix': 'High probability for this fault',
            'Also check': 'Used in a meaningful share of repairs',
            'Care & upsell': 'Consumables often sold on this repair',
            Labour: 'Service product',
            'Other on job': 'Products Required added elsewhere'
        };
        const parts = (this.partsData && this.partsData.parts) || [];
        return order
            .map((cat) => ({
                key: cat,
                label: cat,
                hint: hints[cat],
                items: parts.filter((p) => p.category === cat).map((p) => this.decoratePart(p))
            }))
            .filter((g) => g.items.length);
    }

    qtyFor(p) {
        if (p.onJob) {
            if (p.productId in this.pendingQty) return this.pendingQty[p.productId];
            return Number(p.plannedQty != null ? p.plannedQty : p.quantity) || 1;
        }
        if (p.productId in this.draftQty) return this.draftQty[p.productId];
        return Number(p.quantity) || 1;
    }

    stepFor(p) {
        return p.isLabor ? 0.5 : 1;
    }

    decoratePart(p) {
        const checked = p.onJob || this.selectedParts.has(p.productId);
        const meta = [p.code, p.groupName].filter(Boolean).join(' · ');
        const qty = this.qtyFor(p);
        const busy = this.busyParts.has(p.productId);
        let price = '';
        if (p.coverage) price = p.coverage;
        else if (p.unitPrice !== undefined && p.unitPrice !== null) {
            const total = Number(p.unitPrice) * qty;
            price = `${total.toLocaleString()} ${p.currencyCode || ''}`.trim();
        }
        return {
            ...p,
            meta,
            checked,
            disabled: this.partsSaving,
            hasProbability: !p.isLabor && p.probability !== undefined && p.probability !== null,
            probabilityLabel: `${p.probability}%`,
            barStyle: `width:${Math.min(100, p.probability || 0)}%`,
            qty,
            qtyLabel: p.isLabor ? `${qty} h` : `${qty}`,
            minusDisabled: busy || this.partsSaving || qty <= this.stepFor(p),
            plusDisabled: busy || this.partsSaving,
            removeDisabled: busy || this.partsSaving,
            price,
            priceClass: p.coverage ? 'part-price part-price--free' : 'part-price',
            rowClass: p.onJob ? 'part-row part-row--onjob' : (checked ? 'part-row part-row--selected' : 'part-row')
        };
    }

    findPart(id) {
        return ((this.partsData && this.partsData.parts) || []).find((p) => p.productId === id);
    }

    handleQtyStep(event) {
        const id = event.currentTarget.dataset.id;
        const dir = Number(event.currentTarget.dataset.dir);
        const p = this.findPart(id);
        if (!p) return;
        const step = this.stepFor(p);
        const next = Math.max(step, Math.round((this.qtyFor(p) + dir * step) * 100) / 100);
        if (!p.onJob) {
            this.draftQty = { ...this.draftQty, [id]: next };
            if (!this.selectedParts.has(id)) this.selectedParts = new Set([...this.selectedParts, id]);
            return;
        }
        // on the job: save (debounced) to Products Required
        this.pendingQty = { ...this.pendingQty, [id]: next };
        clearTimeout(this._qtyTimers[id]);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._qtyTimers[id] = setTimeout(() => this.saveQty(id, next), 600);
    }

    saveQty(id, qty) {
        this.busyParts = new Set([...this.busyParts, id]);
        updateProductRequiredQuantity({ workOrderId: this.recordId, productId: id, quantity: qty })
            .then(() => {
                const p = this.findPart(id);
                if (p) p.plannedQty = qty;
                this.notifyJobChanged();
            })
            .catch((e) => {
                const pending = { ...this.pendingQty };
                delete pending[id];
                this.pendingQty = pending;
                this.toast('Could not update quantity', e, 'error');
            })
            .finally(() => {
                const b = new Set(this.busyParts); b.delete(id); this.busyParts = b;
            });
    }

    handleRemovePart(event) {
        const id = event.currentTarget.dataset.id;
        const p = this.findPart(id);
        this.busyParts = new Set([...this.busyParts, id]);
        removeProductRequired({ workOrderId: this.recordId, productId: id })
            .then(() => {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Removed from job',
                    message: `${p ? p.name : 'Part'} was removed from Products Required`,
                    variant: 'success'
                }));
                this.notifyJobChanged();
                this.loadParts(false);
            })
            .catch((e) => this.toast('Could not remove part', e, 'error'))
            .finally(() => {
                const b = new Set(this.busyParts); b.delete(id); this.busyParts = b;
            });
    }

    notifyJobChanged() {
        notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
        this.dispatchEvent(new RefreshEvent());
    }

    toast(title, e, variant) {
        this.dispatchEvent(new ShowToastEvent({
            title,
            message: (e && e.body && e.body.message) || (typeof e === 'string' ? e : 'Unknown error'),
            variant
        }));
    }

    // ---- Collapse / expand the Asset Insights panel ----
    get collapseKey() {
        return `assetDetails:insightsCollapsed:${this.recordId || 'none'}`;
    }

    connectedCallback() {
        try {
            this.insightsCollapsed = window.localStorage.getItem(this.collapseKey) === '1';
        } catch (e) { /* storage unavailable */ }
    }

    get insightsExpanded() {
        return !this.insightsCollapsed;
    }

    get insightsAriaExpanded() {
        return this.insightsCollapsed ? 'false' : 'true';
    }

    get toggleIcon() {
        return this.insightsCollapsed ? 'utility:chevrondown' : 'utility:chevronup';
    }

    get toggleTitle() {
        return (this.insightsCollapsed ? 'Show ' : 'Hide ') + this.panelTitle;
    }

    get einsteinCardClass() {
        return this.insightsCollapsed ? 'einstein-card einstein-card--collapsed' : 'einstein-card';
    }

    get showRefresh() {
        return this.hasAiTemplate && !this.insightsCollapsed;
    }

    get collapsedSummary() {
        const parts = (this.partsData && this.partsData.parts) || [];
        const onJob = parts.filter((p) => p.onJob).length;
        if (onJob) return `${onJob} item${onJob === 1 ? '' : 's'} on job · Show`;
        return 'Show';
    }

    setInsightsCollapsed(value) {
        this.insightsCollapsed = value;
        try {
            if (value) window.localStorage.setItem(this.collapseKey, '1');
            else window.localStorage.removeItem(this.collapseKey);
        } catch (e) { /* storage unavailable */ }
    }

    handleToggleInsights() {
        this.setInsightsCollapsed(!this.insightsCollapsed);
    }

    handleCollapseInsights() {
        this.setInsightsCollapsed(true);
    }

    disconnectedCallback() {
        Object.values(this._qtyTimers).forEach((t) => clearTimeout(t));
    }

    get partsMessage() {
        if (!this.partsData) return '';
        if (this.partsData.message) return this.partsData.message;
        return (this.partsData.parts || []).length ? '' : 'No part suggestions for this asset.';
    }

    get partsSummary() {
        const d = this.partsData;
        if (!d || !d.sampleSize) return '';
        return `Learned from ${d.sampleSize} completed ${d.faultCode ? d.faultCode + ' ' : ''}repairs`;
    }

    get selectedCount() {
        return this.selectedParts.size;
    }

    get addDisabled() {
        return this.selectedParts.size === 0 || this.partsSaving;
    }

    get addLabel() {
        const n = this.selectedParts.size;
        return n ? `Add ${n} to work order` : 'Select parts to add';
    }

    handlePartToggle(event) {
        const id = event.currentTarget.dataset.id;
        const sel = new Set(this.selectedParts);
        if (event.target.checked) sel.add(id); else sel.delete(id);
        this.selectedParts = sel;
    }

    handleAddParts() {
        const ids = [...this.selectedParts];
        if (!ids.length) return;
        const quantities = {};
        ids.forEach((id) => {
            const p = this.findPart(id);
            if (p && !p.onJob) quantities[id] = this.qtyFor(p);
        });
        this.partsSaving = true;
        addProductsRequiredWithQuantities({ workOrderId: this.recordId, quantities })
            .then((n) => {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Products Required updated',
                    message: `${n} item${n === 1 ? '' : 's'} added to the work order`,
                    variant: 'success'
                }));
                this.selectedParts = new Set();
                this.draftQty = {};
                this.notifyJobChanged();
                this.loadParts(false);
            })
            .catch((e) => {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Could not add parts',
                    message: (e && e.body && e.body.message) || 'Unknown error',
                    variant: 'error'
                }));
            })
            .finally(() => { this.partsSaving = false; });
    }

    get parentFields() {
        if (!this.objectApiName || !this.assetLookupField) return [];
        const fields = [`${this.objectApiName}.${this.assetLookupField}`];
        if (this.mapAddressField) fields.push(`${this.objectApiName}.${this.mapAddressField}`);
        // Compound address parts for the map (when no single mapAddressField is set)
        if (this.showMapButton && !this.mapAddressField) {
            [this.mapStreetField, this.mapCityField, this.mapStateField,
             this.mapPostalCodeField, this.mapCountryField]
                .filter(Boolean)
                .forEach((f) => fields.push(`${this.objectApiName}.${f}`));
        }
        return fields;
    }

    /** Read a parent field value safely by API name */
    parentValue(fieldApiName) {
        if (!this.parentData || !fieldApiName) return '';
        return getFieldValue(this.parentData, `${this.objectApiName}.${fieldApiName}`) || '';
    }

    get assetFields() {
        const fields = [...BASE_ASSET_FIELDS];
        if (this.insightsFieldApiName) fields.push(`Asset.${this.insightsFieldApiName}`);
        return fields;
    }

    // ---- State flags ----
    get isLoading() {
        if (!this.recordId) return false;
        if (!this.parentResolved) return true;
        if (this.assetId && !this.assetResolved) return true;
        return false;
    }

    get hasError() {
        return !!(this.parentError || this.assetError);
    }

    get noAsset() {
        return this.parentResolved && !this.parentError && !this.assetId;
    }

    get showMapIcon() {
        return this.showMapButton && !!this.assetId;
    }

    get hasPromptTemplate() {
        return this.showPromptTemplate && !!this.promptTemplate;
    }

    // ---- Field value getters ----
    get assetName() {
        return getFieldValue(this.assetData, 'Asset.Name') || '—';
    }

    get serialNumber() {
        return getFieldValue(this.assetData, 'Asset.SerialNumber') || '—';
    }

    get status() {
        return getFieldValue(this.assetData, 'Asset.Status') || '—';
    }

    get statusBadgeClass() {
        const s = this.status;
        if (s === 'Installed') return 'badge badge--green';
        if (s === 'Purchased') return 'badge badge--blue';
        if (s === 'Shipped') return 'badge badge--yellow';
        if (s === 'Obsolete' || s === 'Registered') return 'badge badge--grey';
        return 'badge badge--grey';
    }

    get warrantyStatus() {
        return (this.warranty && this.warranty.status) || '—';
    }

    get warrantyDetail() {
        if (!this.warranty || !this.warranty.detail) return '';
        const on = this.warranty.coveredAssetName ? ` (${this.warranty.coveredAssetName})` : '';
        return `${this.warranty.detail}${on}`;
    }

    get warrantyBadgeClass() {
        const s = this.warrantyStatus;
        if (s === 'In Warranty') return 'badge badge--green';
        if (s === 'Out of Warranty') return 'badge badge--red';
        return 'badge badge--grey';
    }

    get installDate() {
        const raw = getFieldValue(this.assetData, 'Asset.InstallDate');
        if (!raw) return '—';
        const d = new Date(raw);
        return `${MONTH[d.getUTCMonth()]} ${d.getUTCDate()}, ${d.getUTCFullYear()}`;
    }

    get locationId() {
        return getFieldValue(this.assetData, 'Asset.LocationId');
    }

    get locationName() {
        return getFieldValue(this.assetData, 'Asset.Location.Name') || '—';
    }

    get accountId() {
        return getFieldValue(this.assetData, 'Asset.AccountId');
    }

    get accountName() {
        return getFieldValue(this.assetData, 'Asset.Account.Name') || '—';
    }

    get partNumber() {
        return getFieldValue(this.assetData, 'Asset.StockKeepingUnit') || '—';
    }

    get einsteinInsight() {
        const generated = this.insightResults[this.currentTemplate];
        if (generated) return generated;
        if (this.currentTemplate !== this.templateList[0]?.api && generated === null) {
            return 'This insight could not be generated. Try refreshing.';
        }
        // Use configured field value if available
        if (this.insightsFieldApiName && this.assetData) {
            const val = getFieldValue(this.assetData, `Asset.${this.insightsFieldApiName}`);
            if (val) return val;
        }
        // Fallback to hardcoded status-based text
        const s = this.status;
        if (s === 'Installed') return 'Performance indicates maintenance is required soon.';
        if (s === 'Purchased') return 'Asset has not yet been installed.';
        if (s === 'Obsolete') return 'Asset is obsolete — consider scheduling replacement.';
        return 'No insights available.';
    }

    // ---- Prompt template ----
    get resolvedPromptTemplate() {
        if (!this.promptTemplate) return '';
        return this.promptTemplate
            .replace(/\{assetName\}/g, this.assetName)
            .replace(/\{serialNumber\}/g, this.serialNumber)
            .replace(/\{status\}/g, this.status)
            .replace(/\{location\}/g, this.locationName)
            .replace(/\{installDate\}/g, this.installDate)
            .replace(/\{account\}/g, this.accountName);
    }

    // ---- Map ----
    get mapMarkers() {
        if (!this.parentData) return [];

        // Legacy single-field mode: one field used as the whole address string.
        if (this.mapAddressField) {
            const addr = this.parentValue(this.mapAddressField);
            if (!addr) return [];
            return [{ location: { Street: addr }, title: this.assetName }];
        }

        // Compound mode: build a full address from the parent's standard address parts,
        // matching how the standard Address card geocodes the pin.
        const location = {};
        const street = this.parentValue(this.mapStreetField);
        const city = this.parentValue(this.mapCityField);
        const state = this.parentValue(this.mapStateField);
        const postalCode = this.parentValue(this.mapPostalCodeField);
        const country = this.parentValue(this.mapCountryField);

        if (street) location.Street = street;
        if (city) location.City = city;
        if (state) location.State = state;
        if (postalCode) location.PostalCode = postalCode;
        if (country) location.Country = country;

        if (Object.keys(location).length === 0) return [];

        const description = [street, [postalCode, city].filter(Boolean).join(' '), country]
            .filter(Boolean)
            .join(', ');

        return [{ location, title: this.assetName, description }];
    }

    get hasMapMarkers() {
        return this.mapMarkers.length > 0;
    }

    // ---- Flow ----
    get flowInputVariables() {
        return [{ name: this.flowInputVariableName, type: 'String', value: this.assetId }];
    }

    // ---- Action handlers ----
    handleAction(event) {
        const value = event.detail.value;
        if (value === 'view') this.navigateToAsset('view');
        else if (value === 'edit') this.navigateToAsset('edit');
        else if (value === 'clone') this.navigateToAsset('clone');
        else if (value === 'flow') this.showFlow = true;
    }

    handleViewAsset() {
        this.navigateToAsset('view');
    }

    handleLocationClick() {
        if (this.locationId) {
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: { recordId: this.locationId, actionName: 'view' }
            });
        }
    }

    handleAccountClick() {
        if (this.accountId) {
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: { recordId: this.accountId, actionName: 'view' }
            });
        }
    }

    handleFlowClose() {
        this.showFlow = false;
    }

    handleFlowBackdropClick() {
        this.showFlow = false;
    }

    handleFlowModalClick(event) {
        event.stopPropagation();
    }

    handleFlowStatusChange(event) {
        const status = event.detail.status;
        if (status === 'FINISHED' || status === 'FINISHED_SCREEN') {
            this.showFlow = false;
            this.dispatchEvent(new ShowToastEvent({
                title: 'Flow Completed',
                message: `${this.flowMenuLabel} completed successfully`,
                variant: 'success'
            }));
        } else if (status === 'ERROR') {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Flow Error',
                message: 'The flow encountered an error',
                variant: 'error'
            }));
        }
    }

    // ---- Map handlers ----
    handleMapOpen() {
        this.showMap = true;
    }

    handleMapClose() {
        this.showMap = false;
    }

    handleMapBackdropClick() {
        this.showMap = false;
    }

    handleMapModalClick(event) {
        event.stopPropagation();
    }

    // ---- Prompt template handlers ----
    handleCopyPrompt() {
        const text = this.resolvedPromptTemplate;
        navigator.clipboard.writeText(text)
            .then(() => {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Copied',
                    message: 'Prompt copied to clipboard',
                    variant: 'success'
                }));
            })
            .catch(() => {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Copy failed',
                    message: 'Could not copy to clipboard',
                    variant: 'error'
                }));
            });
    }

    navigateToAsset(action) {
        if (this.assetId) {
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: { recordId: this.assetId, actionName: action }
            });
        }
    }
}