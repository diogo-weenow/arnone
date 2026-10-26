import { LightningElement, track } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import FORM_FACTOR from '@salesforce/client/formFactor';
import PAPAPARSE from '@salesforce/resourceUrl/papaparse';

import getBus from '@salesforce/apex/ImportacaoLeadsController.getBus';
import getPerfis from '@salesforce/apex/ImportacaoLeadsController.getPerfis';
import iniciarLote from '@salesforce/apex/ImportacaoLeadsController.iniciarLote';
import adicionarLinhas from '@salesforce/apex/ImportacaoLeadsController.adicionarLinhas';
import classificar from '@salesforce/apex/ImportacaoLeadsController.classificar';
import confirmar from '@salesforce/apex/ImportacaoLeadsController.confirmar';
import consultarStatus from '@salesforce/apex/ImportacaoLeadsController.consultarStatus';

import {
    MSG_EXCEL,
    MSG_LEMIT,
    CHAVES_LEMIT,
    decodificar,
    detectarDelimitador,
    ehCabecalhoLemit,
    casarColuna,
    colunaTemNotacao,
    lerBytes
} from './parser';

const CHUNK = 250;
const POLL_MS = 3000;
const LIMITE_CELULAR = 500;
const TITULO = 'Importação de leads';

const PASSOS = [
    { value: 'origem', label: 'Origem' },
    { value: 'diagnostico', label: 'Diagnóstico' },
    { value: 'revisao', label: 'Revisão' },
    { value: 'processamento', label: 'Processamento' }
];

export default class ImportacaoLeads extends NavigationMixin(LightningElement) {
    passos = PASSOS;
    @track passo = 'origem';
    @track carregando = false;
    @track mensagemProgresso = '';

    papaCarregado = false;
    pequeno = FORM_FACTOR === 'Small';

    // Origem
    @track bus = [];
    @track perfis = [];
    buSelecionada = '';
    perfilSelecionado = '';

    // Arquivo e diagnóstico
    nomeArquivo;
    cabecalhos = [];
    linhasArquivo = [];
    @track diagnostico;
    @track mapeamentos = [];
    @track colunaChave = '';
    @track colunaCompany = '';
    @track colunaLastName = '';

    // Revisão e processamento
    loteId;
    @track preview;
    @track multiplos = [];
    @track status;
    _pollId;

    // ---------------------------------------------------------------- ciclo de vida

    connectedCallback() {
        this.carregarBus();
    }

    renderedCallback() {
        if (this.papaCarregado) {
            return;
        }
        this.papaCarregado = true;
        loadScript(this, PAPAPARSE).catch((e) => {
            this.papaCarregado = false;
            this.erro('Falha ao carregar o leitor de arquivo.', e);
        });
    }

    disconnectedCallback() {
        this.pararPolling();
    }

    async carregarBus() {
        try {
            this.bus = (await getBus()) || [];
            if (this.bus.length === 1) {
                await this.selecionarBu(this.bus[0].value);
            }
        } catch (e) {
            this.erro('Falha ao carregar as unidades.', e);
        }
    }

    // ---------------------------------------------------------------- passo 1: origem

    get opcoesBu() {
        return this.bus.map((b) => ({ label: b.label, value: b.value }));
    }

    get semBu() {
        return this.bus.length === 0;
    }

    get opcoesPerfil() {
        return this.perfis.map((p) => ({ label: p.label, value: p.developerName }));
    }

    get temPerfis() {
        return this.perfis.length > 0;
    }

    get perfil() {
        return this.perfis.find((p) => p.developerName === this.perfilSelecionado);
    }

    get semPerfil() {
        return !this.perfil;
    }

    get descricaoPerfil() {
        return this.perfil ? this.perfil.descricao : '';
    }

    handleBu(event) {
        this.selecionarBu(event.detail.value);
    }

    async selecionarBu(bu) {
        this.buSelecionada = bu;
        this.perfilSelecionado = '';
        this.perfis = [];
        try {
            this.perfis = (await getPerfis({ bu })) || [];
            if (this.perfis.length === 1) {
                this.perfilSelecionado = this.perfis[0].developerName;
            }
        } catch (e) {
            this.erro('Falha ao carregar os perfis da unidade.', e);
        }
    }

    handlePerfil(event) {
        this.perfilSelecionado = event.detail.value;
    }

    async handleArquivo(event) {
        const arquivos =
            (event.detail && event.detail.files) ||
            (event.target && event.target.files);
        const arquivo = arquivos && arquivos[0];
        if (!arquivo || !this.perfil) {
            return;
        }
        if (!window.Papa) {
            this.erro('O leitor de arquivo ainda não está pronto. Tente de novo.');
            return;
        }
        this.carregando = true;
        this.mensagemProgresso = 'Lendo o arquivo...';
        try {
            const bytes = await lerBytes(arquivo);
            this.nomeArquivo = arquivo.name;
            this.analisarTexto(bytes);
        } catch (e) {
            this.erro('Não foi possível ler o arquivo.', e);
        } finally {
            this.carregando = false;
            this.mensagemProgresso = '';
        }
    }

    /** Decodifica, detecta o delimitador, faz o parse e monta o diagnóstico. */
    analisarTexto(bytes) {
        const { texto, encoding } = decodificar(bytes);
        const delimitador = detectarDelimitador(texto);
        const res = window.Papa.parse(texto, {
            header: true,
            delimiter: delimitador.valor,
            skipEmptyLines: 'greedy'
        });
        const campos = ((res.meta && res.meta.fields) || []).filter(
            (c) => c !== undefined && c !== null && String(c).trim() !== ''
        );
        const dados = (res.data || []).filter((r) =>
            Object.keys(r).some((k) => r[k] && String(r[k]).trim() !== '')
        );
        this.cabecalhos = campos;
        this.linhasArquivo = dados;

        const p = this.perfil;
        this.colunaChave = casarColuna(campos, p.colunaChave);
        this.colunaCompany = p.criarSemMatch ? casarColuna(campos, p.colunaCompany) : '';
        this.colunaLastName = p.criarSemMatch ? casarColuna(campos, p.colunaLastName) : '';
        this.mapeamentos = (p.mapeamentos || []).map((m) => ({
            campoLead: m.campoLead,
            label: m.label,
            politica: m.politica,
            usarNaCriacao: m.usarNaCriacao,
            tipoConversao: m.tipoConversao,
            colunaSugerida: m.coluna,
            coluna: casarColuna(campos, m.coluna)
        }));
        this.diagnostico = {
            encoding,
            delimitador: delimitador.rotulo,
            linhas: dados.length,
            ehLemit: ehCabecalhoLemit(campos)
        };
        this.passo = 'diagnostico';
    }

    // ---------------------------------------------------------------- passo 2: diagnóstico

    /** Diagnóstico completo, recalculado a cada troca de coluna. */
    get diagnosticoView() {
        if (!this.diagnostico) {
            return undefined;
        }
        const usadas = new Set(
            [this.colunaChave, this.colunaCompany, this.colunaLastName]
                .concat(this.mapeamentos.map((m) => m.coluna))
                .filter((c) => c)
        );
        return {
            ...this.diagnostico,
            reconhecidas: this.cabecalhos.filter((c) => usadas.has(c)),
            naoReconhecidas: this.cabecalhos.filter((c) => !usadas.has(c)),
            bloqueios: this.bloqueios,
            avisos: this.avisos
        };
    }

    get bloqueios() {
        const b = [];
        if (!this.diagnostico) {
            return b;
        }
        const p = this.perfil;
        const colunasNotacao = [this.colunaChave];
        if (this.diagnostico.ehLemit) {
            colunasNotacao.push(...CHAVES_LEMIT);
        }
        if (colunasNotacao.some((c) => colunaTemNotacao(this.linhasArquivo, c))) {
            b.push({ id: 'excel', mensagem: MSG_EXCEL });
        }
        if (this.diagnostico.ehLemit && p && p.layout === 'GENERICO') {
            b.push({ id: 'lemit', mensagem: MSG_LEMIT });
        }
        if (this.linhasArquivo.length === 0) {
            b.push({ id: 'vazio', mensagem: 'O arquivo está vazio ou sem cabeçalho.' });
        }
        if (p && this.linhasArquivo.length > p.maxLinhas) {
            b.push({
                id: 'max',
                mensagem: `O arquivo tem ${this.linhasArquivo.length} linhas; o máximo é ${p.maxLinhas}.`
            });
        }
        return b;
    }

    get avisos() {
        const a = [];
        if (this.diagnostico && !this.colunaChave) {
            const doc = this.perfil ? this.perfil.chave : 'chave';
            a.push({
                id: 'chave',
                mensagem: `Escolha a coluna do ${doc}: é a chave de casamento.`
            });
        }
        if (this.pequeno && this.linhasArquivo.length > LIMITE_CELULAR) {
            a.push({
                id: 'celular',
                mensagem: 'Use o computador para revisar arquivos com mais de 500 linhas'
            });
        }
        return a;
    }

    get bloqueado() {
        return this.bloqueios.length > 0;
    }

    get naoPodeAnalisar() {
        return this.bloqueado || !this.colunaChave || this.carregando;
    }

    handleColuna(event) {
        const { alvo, valor } = event.detail;
        if (alvo === 'chave') {
            this.colunaChave = valor;
        } else if (alvo === 'company') {
            this.colunaCompany = valor;
        } else if (alvo === 'lastName') {
            this.colunaLastName = valor;
        } else {
            this.mapeamentos = this.mapeamentos.map((m) => {
                return m.campoLead === alvo ? { ...m, coluna: valor } : m;
            });
        }
    }

    async analisar() {
        if (this.naoPodeAnalisar) {
            return;
        }
        this.carregando = true;
        this.mensagemProgresso = 'Criando o lote...';
        try {
            const total = this.linhasArquivo.length;
            this.loteId = await iniciarLote({
                perfilDeveloperName: this.perfilSelecionado,
                nomeArquivo: this.nomeArquivo,
                totalLinhas: total,
                diagnostico: JSON.stringify(this.resumoDiagnostico())
            });
            const payload = this.montarLinhas();
            for (let i = 0; i < payload.length; i += CHUNK) {
                this.mensagemProgresso = `Enviando linhas ${i + 1}–${Math.min(
                    i + CHUNK,
                    total
                )} de ${total}...`;
                // Enviado como string JSON: um Map<String,String> dentro de um
                // tipo Apex não é preenchido pela marshalling nativa LWC->Apex.
                // Sequencial de propósito: limita heap/request por chamada.
                // eslint-disable-next-line no-await-in-loop
                await adicionarLinhas({
                    loteId: this.loteId,
                    linhasJson: JSON.stringify(payload.slice(i, i + CHUNK))
                });
            }
            this.mensagemProgresso = 'Classificando o casamento...';
            this.preview = await classificar({ loteId: this.loteId });
            this.multiplos = (this.preview.multiplos || []).map((l) => ({
                ...l,
                leadsAlvo: (l.leadsAlvo || []).map((a) => ({ ...a }))
            }));
            this.passo = 'revisao';
        } catch (e) {
            this.erro('Falha ao analisar o arquivo.', e);
        } finally {
            this.carregando = false;
            this.mensagemProgresso = '';
        }
    }

    resumoDiagnostico() {
        const d = this.diagnosticoView;
        return {
            encoding: d.encoding,
            delimitador: d.delimitador,
            linhas: d.linhas,
            reconhecidas: d.reconhecidas,
            naoReconhecidas: d.naoReconhecidas,
            colunaChave: this.colunaChave,
            colunaCompany: this.colunaCompany,
            colunaLastName: this.colunaLastName,
            mapeamento: this.mapeamentos
                .filter((m) => m.coluna)
                .map((m) => ({ coluna: m.coluna, campo: m.campoLead, politica: m.politica }))
        };
    }

    montarLinhas() {
        const maps = this.mapeamentos.filter((m) => m.coluna);
        return this.linhasArquivo.map((row, idx) => {
            const valores = {};
            maps.forEach((m) => {
                valores[m.campoLead] = this.valorCelula(row, m.coluna);
            });
            if (this.colunaCompany) {
                valores.Company = this.valorCelula(row, this.colunaCompany);
            }
            if (this.colunaLastName) {
                valores.LastName = this.valorCelula(row, this.colunaLastName);
            }
            return {
                numeroLinha: idx + 1,
                chave: this.valorCelula(row, this.colunaChave),
                valores
            };
        });
    }

    valorCelula(row, coluna) {
        const v = row[coluna];
        return v === undefined || v === null ? '' : String(v).trim();
    }

    // ---------------------------------------------------------------- passo 3: revisão

    handleSelecao(event) {
        const selecoes = event.detail.selecoes || {};
        this.multiplos = this.multiplos.map((l) => {
            if (!(l.linhaId in selecoes)) {
                return l;
            }
            const escolhidos = new Set(selecoes[l.linhaId]);
            return {
                ...l,
                leadsAlvo: l.leadsAlvo.map((a) => {
                    return { ...a, selecionado: escolhidos.has(a.id) };
                })
            };
        });
    }

    get multiplosComEscolha() {
        return this.multiplos.filter((l) => l.leadsAlvo.some((a) => a.selecionado)).length;
    }

    get resumoConfirmacao() {
        const p = this.preview;
        if (!p) {
            return [];
        }
        const itens = [];
        const atualizar = p.matchUnico + this.multiplosComEscolha;
        itens.push({
            id: 'atualizar',
            texto: `${atualizar} linha(s) atualizarão leads existentes.`
        });
        if (p.criarSemMatch) {
            const destino =
                p.modoDono === 'REGRA_ATRIBUICAO'
                    ? 'atribuídos pela regra de atribuição da unidade'
                    : 'distribuídos';
            itens.push({
                id: 'criar',
                texto: `${p.semMatch} leads serão criados e ${destino}.`
            });
        } else {
            itens.push({ id: 'criar', texto: 'Nenhum lead será criado: este perfil só atualiza.' });
        }
        const ignorados = p.total - atualizar - (p.criarSemMatch ? p.semMatch : 0);
        itens.push({ id: 'ignorar', texto: `${ignorados} linha(s) serão ignoradas.` });
        return itens;
    }

    async confirmarProcessamento() {
        this.carregando = true;
        try {
            const selecoes = this.multiplos.map((l) => ({
                linhaId: l.linhaId,
                acao: 'ATUALIZAR',
                leadsSelecionados: l.leadsAlvo.filter((a) => a.selecionado).map((a) => a.id)
            }));
            await confirmar({ loteId: this.loteId, selecoes });
            this.passo = 'processamento';
            this.iniciarPolling();
        } catch (e) {
            this.erro('Falha ao confirmar.', e);
        } finally {
            this.carregando = false;
        }
    }

    // ---------------------------------------------------------------- passo 4: processamento

    iniciarPolling() {
        this.pararPolling();
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._pollId = setInterval(() => this.verificarStatus(), POLL_MS);
        this.verificarStatus();
    }

    pararPolling() {
        if (this._pollId) {
            clearInterval(this._pollId);
            this._pollId = undefined;
        }
    }

    verificarStatus() {
        consultarStatus({ loteId: this.loteId })
            .then((s) => {
                this.status = s;
                if (this.concluido) {
                    this.pararPolling();
                }
            })
            .catch((e) => {
                this.pararPolling();
                this.erro('Falha ao consultar o status.', e);
            });
    }

    get concluido() {
        const s = this.status;
        return (
            !!s &&
            (s.status === 'Concluído' ||
                s.status === 'Concluído com erros' ||
                s.status === 'Erro' ||
                s.jobStatus === 'Failed' ||
                s.jobStatus === 'Aborted')
        );
    }

    get progresso() {
        const s = this.status;
        if (!s) {
            return 0;
        }
        if (this.concluido) {
            return 100;
        }
        return s.jobItensTotal > 0
            ? Math.round((100 * s.jobItensProcessados) / s.jobItensTotal)
            : 0;
    }

    get resumoFinal() {
        const s = this.status;
        if (!s) {
            return [];
        }
        return [
            { id: 'st', rotulo: 'Status', valor: s.status },
            { id: 'at', rotulo: 'Linhas atualizadas', valor: s.qtdAtualizados },
            { id: 'cr', rotulo: 'Leads criados', valor: s.qtdCriados },
            { id: 'ig', rotulo: 'Ignoradas', valor: s.qtdIgnorados },
            { id: 'er', rotulo: 'Erros', valor: s.qtdErros }
        ];
    }

    abrirLote() {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: this.loteId,
                objectApiName: 'Importacao_Lote__c',
                actionName: 'view'
            }
        });
    }

    recomecar() {
        this.pararPolling();
        this.passo = 'origem';
        this.nomeArquivo = undefined;
        this.cabecalhos = [];
        this.linhasArquivo = [];
        this.diagnostico = undefined;
        this.mapeamentos = [];
        this.colunaChave = '';
        this.colunaCompany = '';
        this.colunaLastName = '';
        this.preview = undefined;
        this.multiplos = [];
        this.status = undefined;
        this.loteId = undefined;
    }

    // ---------------------------------------------------------------- getters de tela

    get ehOrigem() {
        return this.passo === 'origem';
    }
    get ehDiagnostico() {
        return this.passo === 'diagnostico';
    }
    get ehRevisao() {
        return this.passo === 'revisao';
    }
    get ehProcessamento() {
        return this.passo === 'processamento';
    }

    get classeAcoes() {
        return this.pequeno
            ? 'slds-m-top_medium slds-grid slds-grid_vertical acoes-pequeno'
            : 'slds-m-top_medium';
    }

    // ---------------------------------------------------------------- util

    erro(msg, e) {
        const detalhe = e ? ' ' + this.reduzirErro(e) : '';
        this.dispatchEvent(
            new ShowToastEvent({
                title: TITULO,
                message: (msg + detalhe).trim(),
                variant: 'error',
                mode: 'sticky'
            })
        );
    }

    reduzirErro(e) {
        if (!e) {
            return '';
        }
        if (Array.isArray(e.body)) {
            return e.body.map((x) => x.message).join(', ');
        }
        if (e.body && e.body.message) {
            return e.body.message;
        }
        if (e.message) {
            return e.message;
        }
        return String(e);
    }
}
