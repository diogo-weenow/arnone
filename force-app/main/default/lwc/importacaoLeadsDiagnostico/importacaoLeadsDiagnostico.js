import { LightningElement, api } from 'lwc';

const NENHUM = '';

/**
 * Importação de leads — passo de diagnóstico: cards do arquivo (encoding,
 * delimitador, linhas, colunas reconhecidas e não reconhecidas, bloqueios) e
 * mapeamento editável. Não guarda estado: cada troca de coluna sobe no evento
 * `colunachange` ({ alvo, valor }) e o pai recalcula o diagnóstico.
 */
export default class ImportacaoLeadsDiagnostico extends LightningElement {
    @api diagnostico;
    @api perfil;
    @api cabecalhos = [];
    @api mapeamentos = [];
    @api colunaChave = NENHUM;
    @api colunaCompany = NENHUM;
    @api colunaLastName = NENHUM;
    @api pequeno = false;

    get opcoesColunas() {
        return [{ label: '— Não usar —', value: NENHUM }].concat(
            (this.cabecalhos || []).map((h) => ({ label: h, value: h }))
        );
    }

    get cards() {
        const d = this.diagnostico || {};
        return [
            { id: 'enc', rotulo: 'Encoding', valor: d.encoding },
            { id: 'del', rotulo: 'Delimitador', valor: d.delimitador },
            { id: 'lin', rotulo: 'Linhas de dados', valor: d.linhas },
            {
                id: 'rec',
                rotulo: 'Colunas reconhecidas',
                valor: (d.reconhecidas || []).length
            },
            {
                id: 'nrec',
                rotulo: 'Colunas não reconhecidas',
                valor: (d.naoReconhecidas || []).length
            },
            {
                id: 'blq',
                rotulo: 'Bloqueios',
                valor: (d.bloqueios || []).length,
                alerta: (d.bloqueios || []).length > 0
            }
        ].map((c) => ({
            ...c,
            classe: c.alerta
                ? 'slds-box slds-box_x-small card-diag card-alerta'
                : 'slds-box slds-box_x-small card-diag'
        }));
    }

    get classeCard() {
        return this.pequeno
            ? 'slds-col slds-size_1-of-2 slds-p-around_xx-small'
            : 'slds-col slds-size_1-of-3 slds-large-size_1-of-6 slds-p-around_xx-small';
    }

    get bloqueios() {
        return (this.diagnostico && this.diagnostico.bloqueios) || [];
    }

    get temBloqueios() {
        return this.bloqueios.length > 0;
    }

    get avisos() {
        return (this.diagnostico && this.diagnostico.avisos) || [];
    }

    get temAvisos() {
        return this.avisos.length > 0;
    }

    get naoReconhecidasTexto() {
        const n = (this.diagnostico && this.diagnostico.naoReconhecidas) || [];
        return n.join(', ');
    }

    get temNaoReconhecidas() {
        return this.naoReconhecidasTexto !== '';
    }

    get criaLeads() {
        return !!(this.perfil && this.perfil.criarSemMatch);
    }

    get rotuloChave() {
        const doc = this.perfil ? this.perfil.chave : 'chave';
        return `Coluna do ${doc} (chave de casamento)`;
    }

    get linhasMapeamento() {
        return (this.mapeamentos || []).map((m) => ({
            ...m,
            politicaTexto:
                m.politica === 'OVERWRITE'
                    ? 'Sobrescreve quando a célula tem valor'
                    : 'Só preenche se o campo estiver vazio'
        }));
    }

    get classeMapa() {
        return this.pequeno ? 'mapa mapa-vertical' : 'mapa';
    }

    get classeLinhaMapa() {
        return this.pequeno
            ? 'slds-grid slds-grid_vertical slds-m-bottom_small'
            : 'slds-grid slds-gutters_small slds-grid_vertical-align-end slds-m-bottom_x-small';
    }

    get classeColunaMapa() {
        return this.pequeno ? 'slds-col slds-size_1-of-1' : 'slds-col slds-size_1-of-2';
    }

    emitir(alvo, valor) {
        this.dispatchEvent(new CustomEvent('colunachange', { detail: { alvo, valor } }));
    }

    handleChave(e) {
        this.emitir('chave', e.detail.value);
    }

    handleCompany(e) {
        this.emitir('company', e.detail.value);
    }

    handleLastName(e) {
        this.emitir('lastName', e.detail.value);
    }

    handleMapeamento(e) {
        this.emitir(e.target.dataset.campo, e.detail.value);
    }
}
