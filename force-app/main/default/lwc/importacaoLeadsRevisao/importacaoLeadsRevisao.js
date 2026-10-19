import { LightningElement, api, track } from 'lwc';

const BALDES = {
    MATCH_UNICO: 'Atualizar (match único)',
    MATCH_MULTIPLO: 'Escolher (match múltiplo)',
    SEM_MATCH: 'Sem match',
    CONVERTIDO: 'Convertido',
    JA_CONTATO: 'Já é contato',
    INVALIDO: 'Inválido',
    DUPLICADO_NO_ARQUIVO: 'Duplicado no arquivo'
};

const COLUNAS_LINHA = [
    { label: 'Linha', fieldName: 'numeroLinha', type: 'number', initialWidth: 80 },
    { label: 'Chave', fieldName: 'chaveOriginal' },
    { label: 'Resultado', fieldName: 'rotuloBalde' },
    { label: 'Ação', fieldName: 'acao', initialWidth: 110 },
    { label: 'Detalhe', fieldName: 'resumo', wrapText: true }
];

const COLUNAS_MULTIPLO = [
    { label: 'Linha', fieldName: 'numeroLinha', type: 'number', initialWidth: 80 },
    { label: 'Chave', fieldName: 'chaveOriginal' },
    { label: 'Lead', fieldName: 'nome' },
    { label: 'Empresa', fieldName: 'empresa' },
    { label: 'Proprietário', fieldName: 'owner' }
];

/**
 * Importação de leads — passo de revisão: tiles clicáveis por balde e a lista do
 * balde escolhido. No desktop, lightning-datatable (no múltiplo, a seleção de
 * linhas escolhe os leads). No celular, lightning-accordion com checkboxes.
 * A escolha no múltiplo sobe no evento `selecaochange` ({ selecoes: {linhaId: [leadId]} }).
 */
export default class ImportacaoLeadsRevisao extends LightningElement {
    @api preview;
    @api multiplos = [];
    @api pequeno = false;
    @track balde;

    get criaLeads() {
        return !!(this.preview && this.preview.criarSemMatch);
    }

    get tiles() {
        const p = this.preview || {};
        const lista = [
            { k: 'MATCH_UNICO', valor: p.matchUnico },
            { k: 'MATCH_MULTIPLO', valor: p.matchMultiplo },
            {
                k: 'SEM_MATCH',
                valor: p.semMatch,
                rotulo: this.criaLeads ? 'Criar (sem match)' : 'Sem match (ignorar)'
            },
            { k: 'CONVERTIDO', valor: p.convertido }
        ];
        if (p.chave === 'CPF') {
            lista.push({ k: 'JA_CONTATO', valor: p.jaContato });
        }
        lista.push({ k: 'INVALIDO', valor: p.invalido });
        if (this.criaLeads) {
            lista.push({ k: 'DUPLICADO_NO_ARQUIVO', valor: p.duplicado });
        }
        const ativo = this.baldeAtivo;
        return lista.map((t) => ({
            ...t,
            rotulo: t.rotulo || BALDES[t.k],
            valor: t.valor || 0,
            pressionado: t.k === ativo ? 'true' : 'false',
            classe:
                'slds-box slds-box_x-small tile' + (t.k === ativo ? ' tile-ativo' : '')
        }));
    }

    get classeTile() {
        return this.pequeno
            ? 'slds-col slds-size_1-of-2 slds-p-around_xx-small'
            : 'slds-col slds-size_1-of-4 slds-large-size_1-of-7 slds-p-around_xx-small';
    }

    /** Balde aberto: o escolhido ou, sem escolha, o múltiplo (se houver) ou o primeiro com linhas. */
    get baldeAtivo() {
        if (this.balde) {
            return this.balde;
        }
        if (this.multiplos && this.multiplos.length) {
            return 'MATCH_MULTIPLO';
        }
        const a = (this.preview && this.preview.amostra) || [];
        return a.length ? a[0].resultadoMatch : 'MATCH_UNICO';
    }

    get rotuloBaldeAtivo() {
        const t = this.tiles.find((x) => x.k === this.baldeAtivo);
        return t ? t.rotulo : '';
    }

    handleTile(event) {
        this.balde = event.currentTarget.dataset.balde;
    }

    get ehMultiplo() {
        return this.baldeAtivo === 'MATCH_MULTIPLO';
    }

    get grande() {
        return !this.pequeno;
    }

    // ---------------------------------------------------------------- linhas do balde

    get linhasBalde() {
        const a = (this.preview && this.preview.amostra) || [];
        return a
            .filter((l) => l.resultadoMatch === this.baldeAtivo)
            .map((l) => ({
                ...l,
                rotuloBalde: BALDES[l.resultadoMatch] || l.resultadoMatch,
                rotuloSecao: `Linha ${l.numeroLinha} — ${l.chaveOriginal || 'sem chave'}`
            }));
    }

    get semLinhas() {
        return this.ehMultiplo
            ? !(this.multiplos && this.multiplos.length)
            : this.linhasBalde.length === 0;
    }

    get colunasLinha() {
        return COLUNAS_LINHA;
    }

    get colunasMultiplo() {
        return COLUNAS_MULTIPLO;
    }

    get linhasMultiplo() {
        const out = [];
        (this.multiplos || []).forEach((l) => {
            (l.leadsAlvo || []).forEach((a) => {
                out.push({
                    chaveTabela: `${l.linhaId}|${a.id}`,
                    linhaId: l.linhaId,
                    leadId: a.id,
                    numeroLinha: l.numeroLinha,
                    chaveOriginal: l.chaveOriginal,
                    nome: a.nome,
                    empresa: a.empresa,
                    owner: a.owner
                });
            });
        });
        return out;
    }

    get selecionadosMultiplo() {
        const out = [];
        (this.multiplos || []).forEach((l) => {
            (l.leadsAlvo || []).forEach((a) => {
                if (a.selecionado) {
                    out.push(`${l.linhaId}|${a.id}`);
                }
            });
        });
        return out;
    }

    get secoesMultiplo() {
        return (this.multiplos || []).map((l) => ({
            ...l,
            rotuloSecao: `Linha ${l.numeroLinha} — ${l.chaveOriginal}`,
            leadsAlvo: (l.leadsAlvo || []).map((a) => ({
                ...a,
                rotulo: `${a.nome} · ${a.empresa || ''} · ${a.owner || ''}`
            }))
        }));
    }

    handleSelecaoTabela(event) {
        const selecoes = {};
        (this.multiplos || []).forEach((l) => {
            selecoes[l.linhaId] = [];
        });
        (event.detail.selectedRows || []).forEach((r) => {
            if (selecoes[r.linhaId]) {
                selecoes[r.linhaId].push(r.leadId);
            }
        });
        this.dispatchEvent(new CustomEvent('selecaochange', { detail: { selecoes } }));
    }

    handleCheckbox(event) {
        const linhaId = event.target.dataset.linha;
        const leadId = event.target.dataset.lead;
        const marcado = event.target.checked;
        const linha = (this.multiplos || []).find((l) => l.linhaId === linhaId);
        if (!linha) {
            return;
        }
        const escolhidos = linha.leadsAlvo
            .filter((a) => (a.id === leadId ? marcado : a.selecionado))
            .map((a) => a.id);
        this.dispatchEvent(
            new CustomEvent('selecaochange', { detail: { selecoes: { [linhaId]: escolhidos } } })
        );
    }
}
