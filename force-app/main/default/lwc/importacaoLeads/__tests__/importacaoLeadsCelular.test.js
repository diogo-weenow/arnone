import { createElement } from 'lwc';
import { TextDecoder as NodeTextDecoder } from 'util';
import ImportacaoLeads from 'c/importacaoLeads';
import getBus from '@salesforce/apex/ImportacaoLeadsController.getBus';
import getPerfis from '@salesforce/apex/ImportacaoLeadsController.getPerfis';
import classificar from '@salesforce/apex/ImportacaoLeadsController.classificar';
import iniciarLote from '@salesforce/apex/ImportacaoLeadsController.iniciarLote';
import adicionarLinhas from '@salesforce/apex/ImportacaoLeadsController.adicionarLinhas';
import { lerBytes } from '../parser';

global.TextDecoder = NodeTextDecoder;

// O transformer do LWC Jest lê o formFactor na carga do módulo: este arquivo
// carrega o componente já como celular.
jest.mock('@salesforce/client/formFactor', () => ({ __esModule: true, default: 'Small' }), {
    virtual: true
});
jest.mock('../parser', () => {
    const real = jest.requireActual('../parser');
    return { ...real, lerBytes: jest.fn() };
});
jest.mock('@salesforce/apex/ImportacaoLeadsController.getBus', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/ImportacaoLeadsController.getPerfis', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/ImportacaoLeadsController.iniciarLote', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/ImportacaoLeadsController.adicionarLinhas', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/ImportacaoLeadsController.classificar', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/ImportacaoLeadsController.confirmar', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/ImportacaoLeadsController.consultarStatus', () => ({ default: jest.fn() }), { virtual: true });

const PERFIL_STE = {
    developerName: 'STE_Atualizacao_CPF',
    label: 'Instituto STech — Atualização por CPF',
    descricao: 'Atualiza leads do Instituto STech pelo CPF. Não cria leads e ignora quem já é contato.',
    bu: 'STE',
    chave: 'CPF',
    layout: 'GENERICO',
    modoDono: 'DISTRIBUICAO_SOL',
    criarSemMatch: false,
    colunaChave: 'CPF',
    maxLinhas: 5000,
    mapeamentos: [{ coluna: 'E-mail', campoLead: 'Email', label: 'Email', politica: 'FILL_BLANK', tipoConversao: 'TEXT' }]
};

// eslint-disable-next-line @lwc/lwc/no-async-operation
const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

async function montarESubir(texto) {
    window.Papa = require('../../../staticresources/papaparse.js');
    const el = createElement('c-importacao-leads', { is: ImportacaoLeads });
    document.body.appendChild(el);
    await flush();
    await flush();
    lerBytes.mockResolvedValue(Uint8Array.from(Buffer.from(texto, 'utf8')));
    el.shadowRoot
        .querySelector('lightning-input.arquivo')
        .dispatchEvent(new CustomEvent('change', { detail: { files: [new File([texto], 'a.csv')] } }));
    await flush();
    await flush();
    await flush();
    return el;
}

describe('c-importacao-leads no celular', () => {
    beforeEach(() => {
        getBus.mockResolvedValue([{ value: 'STE', label: 'Instituto STech' }]);
        getPerfis.mockResolvedValue([PERFIL_STE]);
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('avisa acima de 500 linhas e monta o mapeamento em lista vertical', async () => {
        let texto = 'CPF;E-mail\n';
        for (let i = 0; i < 501; i++) {
            texto += `12345678909;a${i}@x.com\n`;
        }
        const el = await montarESubir(texto);
        const diag = el.shadowRoot.querySelector('c-importacao-leads-diagnostico');
        expect(diag.pequeno).toBe(true);
        expect(diag.diagnostico.avisos.map((a) => a.mensagem)).toContain(
            'Use o computador para revisar arquivos com mais de 500 linhas'
        );
        expect(diag.shadowRoot.querySelector('.mapa-vertical')).not.toBeNull();
        expect(el.shadowRoot.querySelector('.acoes-pequeno')).not.toBeNull();
    });

    it('passa o modo celular à revisão, que usa o acordeão (cenário 29)', async () => {
        iniciarLote.mockResolvedValue('a0X000000000001');
        adicionarLinhas.mockResolvedValue();
        classificar.mockResolvedValue({
            loteId: 'a0X000000000001',
            loteNome: 'IMP-000001',
            total: 1,
            matchUnico: 1,
            matchMultiplo: 0,
            semMatch: 0,
            convertido: 0,
            jaContato: 0,
            invalido: 0,
            duplicado: 0,
            criarSemMatch: false,
            chave: 'CPF',
            multiplos: [],
            amostra: [{ linhaId: 'l1', numeroLinha: 1, chaveOriginal: '12345678909', resultadoMatch: 'MATCH_UNICO', acao: 'ATUALIZAR', resumo: '' }]
        });
        const el = await montarESubir('CPF;E-mail\n12345678909;a@x.com\n');
        el.shadowRoot.querySelector('lightning-button.botao-analisar').click();
        await flush();
        await flush();
        const rev = el.shadowRoot.querySelector('c-importacao-leads-revisao');
        expect(rev.pequeno).toBe(true);
        expect(rev.shadowRoot.querySelector('lightning-accordion.acordeao-linhas')).not.toBeNull();
        expect(rev.shadowRoot.querySelector('lightning-datatable')).toBeNull();
        expect(el.shadowRoot.querySelector('.confirmacao').textContent).toContain(
            'Nenhum lead será criado: este perfil só atualiza.'
        );
    });
});
