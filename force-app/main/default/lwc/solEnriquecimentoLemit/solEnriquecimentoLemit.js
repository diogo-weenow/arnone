import { LightningElement, track } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import PAPAPARSE from '@salesforce/resourceUrl/papaparse';

import getConfiguracao from '@salesforce/apex/SOLEnriquecimentoController.getConfiguracao';
import iniciarLote from '@salesforce/apex/SOLEnriquecimentoController.iniciarLote';
import adicionarLinhas from '@salesforce/apex/SOLEnriquecimentoController.adicionarLinhas';
import classificar from '@salesforce/apex/SOLEnriquecimentoController.classificar';
import confirmar from '@salesforce/apex/SOLEnriquecimentoController.confirmar';
import consultarStatus from '@salesforce/apex/SOLEnriquecimentoController.consultarStatus';

const CHUNK = 250;
const POLL_MS = 3000;
const NENHUM = '';

export default class SolEnriquecimentoLemit extends LightningElement {
    @track step = 'upload'; // upload | mapping | preview | processing | done
    @track carregando = false;
    @track mensagemProgresso = '';

    papaCarregado = false;
    config;
    maxLinhas = 5000;

    nomeArquivo;
    cabecalhos = [];
    linhasArquivo = [];

    // Designações especiais e mapeamento de enriquecimento.
    @track colunaCnpj = NENHUM;
    @track colunaCompany = NENHUM;
    @track colunaLastName = NENHUM;
    @track mapeamentos = []; // {campoLead,label,politica,usarNaCriacao,tipoConversao,coluna}

    loteId;
    jobId;
    @track preview;
    @track multiplos = [];
    @track status;
    _pollId;

    // ---------------------------------------------------------------- lifecycle

    renderedCallback() {
        if (this.papaCarregado) {
            return;
        }
        this.papaCarregado = true;
        loadScript(this, PAPAPARSE)
            .then(() => this.carregarConfig())
            .catch((e) => {
                this.papaCarregado = false;
                this.erro('Falha ao carregar o leitor de CSV.', e);
            });
    }

    carregarConfig() {
        getConfiguracao()
            .then((cfg) => {
                this.config = cfg;
                this.maxLinhas = cfg.maxLinhas;
                this.mapeamentos = (cfg.mapeamentos || []).map((m) => ({
                    campoLead: m.campoLead,
                    label: m.label,
                    politica: m.politica,
                    usarNaCriacao: m.usarNaCriacao,
                    tipoConversao: m.tipoConversao,
                    colunaSugerida: m.coluna,
                    coluna: NENHUM
                }));
            })
            .catch((e) => this.erro('Falha ao carregar a configuração.', e));
    }

    // ---------------------------------------------------------------- upload

    get aceitaArquivo() {
        return ['.csv', '.txt'];
    }

    handleArquivo(event) {
        const arquivo = event.target.files && event.target.files[0];
        if (!arquivo) {
            return;
        }
        if (!window.Papa) {
            this.erro('O leitor de CSV ainda não está pronto. Tente de novo.');
            return;
        }
        this.carregando = true;
        this.nomeArquivo = arquivo.name;
        // eslint-disable-next-line no-undef
        window.Papa.parse(arquivo, {
            header: true,
            skipEmptyLines: 'greedy',
            complete: (res) => this.aposParse(res),
            error: (err) => {
                this.carregando = false;
                this.erro('Não foi possível ler o arquivo.', err);
            }
        });
    }

    aposParse(res) {
        this.carregando = false;
        const campos = (res.meta && res.meta.fields) || [];
        const dados = (res.data || []).filter((r) =>
            Object.keys(r).some((k) => r[k] && String(r[k]).trim() !== '')
        );
        if (!campos.length || !dados.length) {
            this.erro('O arquivo está vazio ou sem cabeçalho.');
            return;
        }
        if (dados.length > this.maxLinhas) {
            this.erro(
                `O arquivo tem ${dados.length} linhas; o máximo é ${this.maxLinhas}.`
            );
            return;
        }
        this.cabecalhos = campos;
        this.linhasArquivo = dados;
        // Pré-preenche o mapeamento casando o cabeçalho com a coluna sugerida.
        this.mapeamentos = this.mapeamentos.map((m) => ({
            ...m,
            coluna: this.casarColuna(m.colunaSugerida)
        }));
        this.colunaCnpj = this.casarColuna('CNPJ');
        this.colunaCompany = this.casarColuna('Razão Social');
        this.colunaLastName = this.casarColuna('Razão Social');
        this.step = 'mapping';
    }

    casarColuna(sugestao) {
        if (!sugestao) {
            return NENHUM;
        }
        const alvo = this.normalizar(sugestao);
        const achado = this.cabecalhos.find(
            (h) => this.normalizar(h) === alvo
        );
        return achado || NENHUM;
    }

    normalizar(s) {
        return String(s || '')
            .toLowerCase()
            .normalize('NFD')
            .replace(/[̀-ͯ]/g, '')
            .replace(/[^a-z0-9]/g, '');
    }

    // ---------------------------------------------------------------- mapping

    get opcoesColunas() {
        return [{ label: '-- Não mapear --', value: NENHUM }].concat(
            this.cabecalhos.map((h) => ({ label: h, value: h }))
        );
    }

    handleCnpj(e) {
        this.colunaCnpj = e.detail.value;
    }
    handleCompany(e) {
        this.colunaCompany = e.detail.value;
    }
    handleLastName(e) {
        this.colunaLastName = e.detail.value;
    }
    handleMapeamento(e) {
        const campo = e.target.dataset.campo;
        const valor = e.detail.value;
        this.mapeamentos = this.mapeamentos.map((m) =>
            m.campoLead === campo ? { ...m, coluna: valor } : m
        );
    }

    get podeGerarPreview() {
        return !!this.colunaCnpj;
    }

    async gerarPreview() {
        if (!this.colunaCnpj) {
            this.erro('Designe a coluna do CNPJ — é a chave de casamento.');
            return;
        }
        this.carregando = true;
        this.mensagemProgresso = 'Criando lote...';
        try {
            const total = this.linhasArquivo.length;
            this.loteId = await iniciarLote({
                nomeArquivo: this.nomeArquivo,
                totalLinhas: total
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

            this.mensagemProgresso = 'Classificando casamento por CNPJ...';
            this.preview = await classificar({ loteId: this.loteId });
            this.multiplos = (this.preview.multiplos || []).map((l) => ({
                ...l,
                leadsAlvo: (l.leadsAlvo || []).map((a) => ({ ...a }))
            }));
            this.step = 'preview';
        } catch (e) {
            this.erro('Falha ao gerar o preview.', e);
        } finally {
            this.carregando = false;
            this.mensagemProgresso = '';
        }
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
                cnpj: this.valorCelula(row, this.colunaCnpj),
                valores
            };
        });
    }

    valorCelula(row, coluna) {
        const v = row[coluna];
        return v === undefined || v === null ? '' : String(v).trim();
    }

    // ---------------------------------------------------------------- preview

    get temPreview() {
        return !!this.preview;
    }

    get resumoBaldes() {
        if (!this.preview) {
            return [];
        }
        const p = this.preview;
        return [
            { k: 'u', rotulo: 'Match único (atualizar)', valor: p.matchUnico },
            { k: 'm', rotulo: 'Match múltiplo (selecionar)', valor: p.matchMultiplo },
            { k: 's', rotulo: 'Sem match (criar)', valor: p.semMatch },
            { k: 'c', rotulo: 'Convertidos (ignorar)', valor: p.convertido },
            { k: 'i', rotulo: 'Inválidos', valor: p.invalido },
            { k: 'd', rotulo: 'Duplicados no arquivo', valor: p.duplicado }
        ];
    }

    get temMultiplos() {
        return this.multiplos && this.multiplos.length > 0;
    }

    handleSelecaoLead(e) {
        const linhaId = e.target.dataset.linha;
        const leadId = e.target.dataset.lead;
        const checked = e.target.checked;
        this.multiplos = this.multiplos.map((l) => {
            if (l.linhaId !== linhaId) {
                return l;
            }
            return {
                ...l,
                leadsAlvo: l.leadsAlvo.map((a) =>
                    a.id === leadId ? { ...a, selecionado: checked } : a
                )
            };
        });
    }

    async confirmarProcessamento() {
        this.carregando = true;
        try {
            const selecoes = this.multiplos.map((l) => ({
                linhaId: l.linhaId,
                acao: 'ATUALIZAR',
                leadsSelecionados: l.leadsAlvo
                    .filter((a) => a.selecionado)
                    .map((a) => a.id)
            }));
            this.jobId = await confirmar({
                loteId: this.loteId,
                selecoes
            });
            this.step = 'processing';
            this.iniciarPolling();
        } catch (e) {
            this.erro('Falha ao confirmar.', e);
        } finally {
            this.carregando = false;
        }
    }

    // ---------------------------------------------------------------- polling

    iniciarPolling() {
        this.pararPolling();
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
                const fim =
                    s.status === 'Concluído' ||
                    s.status === 'Concluído com erros' ||
                    s.status === 'Erro' ||
                    s.jobStatus === 'Completed' ||
                    s.jobStatus === 'Failed' ||
                    s.jobStatus === 'Aborted';
                if (fim) {
                    this.pararPolling();
                    this.step = 'done';
                }
            })
            .catch((e) => {
                this.pararPolling();
                this.erro('Falha ao consultar o status.', e);
            });
    }

    disconnectedCallback() {
        this.pararPolling();
    }

    // ---------------------------------------------------------------- done

    get temStatus() {
        return !!this.status;
    }

    recomecar() {
        this.pararPolling();
        this.step = 'upload';
        this.nomeArquivo = undefined;
        this.cabecalhos = [];
        this.linhasArquivo = [];
        this.preview = undefined;
        this.multiplos = [];
        this.status = undefined;
        this.loteId = undefined;
        this.jobId = undefined;
        this.colunaCnpj = NENHUM;
        this.colunaCompany = NENHUM;
        this.colunaLastName = NENHUM;
        this.mapeamentos = (this.config.mapeamentos || []).map((m) => ({
            campoLead: m.campoLead,
            label: m.label,
            politica: m.politica,
            usarNaCriacao: m.usarNaCriacao,
            tipoConversao: m.tipoConversao,
            colunaSugerida: m.coluna,
            coluna: NENHUM
        }));
    }

    // ---------------------------------------------------------------- getters UI

    get ehUpload() {
        return this.step === 'upload';
    }
    get ehMapping() {
        return this.step === 'mapping';
    }
    get ehPreview() {
        return this.step === 'preview';
    }
    get ehProcessing() {
        return this.step === 'processing';
    }
    get ehDone() {
        return this.step === 'done';
    }

    // ---------------------------------------------------------------- util

    erro(msg, e) {
        const detalhe = e ? ' ' + this.reduzirErro(e) : '';
        this.dispatchEvent(
            new ShowToastEvent({
                title: 'Enriquecimento Lemit',
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
