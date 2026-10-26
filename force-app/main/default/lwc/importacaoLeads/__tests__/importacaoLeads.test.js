import { createElement } from 'lwc';
import { TextDecoder as NodeTextDecoder } from 'util';
import ImportacaoLeads from 'c/importacaoLeads';
import getBus from '@salesforce/apex/ImportacaoLeadsController.getBus';
import getPerfis from '@salesforce/apex/ImportacaoLeadsController.getPerfis';
import iniciarLote from '@salesforce/apex/ImportacaoLeadsController.iniciarLote';
import adicionarLinhas from '@salesforce/apex/ImportacaoLeadsController.adicionarLinhas';
import classificar from '@salesforce/apex/ImportacaoLeadsController.classificar';
import { lerBytes, MSG_EXCEL, MSG_LEMIT, CABECALHO_LEMIT } from '../parser';

global.TextDecoder = NodeTextDecoder;

let mockFormFactor = 'Large';
jest.mock(
    '@salesforce/client/formFactor',
    () => ({
        __esModule: true,
        get default() {
            return mockFormFactor;
        }
    }),
    { virtual: true }
);

// Leitura do arquivo trocada por bytes do Node (evita diferença de realm do jsdom).
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

const PERFIL_SOL = {
    developerName: 'SOL_Generico',
    label: 'Arnone Soluções — CNPJ',
    descricao: 'Atualiza leads da Arnone Soluções pelo CNPJ e cria os que não existem, que entram na distribuição automática.',
    bu: 'SOL',
    chave: 'CNPJ',
    layout: 'GENERICO',
    modoDono: 'DISTRIBUICAO_SOL',
    criarSemMatch: true,
    colunaChave: 'CNPJ',
    colunaCompany: 'Razão Social',
    colunaLastName: 'Razão Social',
    maxLinhas: 5000,
    mapeamentos: [{ coluna: 'Telefone', campoLead: 'Phone', label: 'Telefone', politica: 'FILL_BLANK', usarNaCriacao: true, tipoConversao: 'TEXT' }]
};

// eslint-disable-next-line @lwc/lwc/no-async-operation
const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

async function montar() {
    window.Papa = require('../../../staticresources/papaparse.js');
    const el = createElement('c-importacao-leads', { is: ImportacaoLeads });
    document.body.appendChild(el);
    await flush();
    await flush();
    return el;
}

async function subir(el, texto) {
    lerBytes.mockResolvedValue(Uint8Array.from(Buffer.from(texto, 'utf8')));
    const input = el.shadowRoot.querySelector('lightning-input.arquivo');
    input.dispatchEvent(
        new CustomEvent('change', { detail: { files: [new File([texto], 'arquivo.csv')] } })
    );
    await flush();
    await flush();
    await flush();
}

function textoBloqueios(el) {
    const diag = el.shadowRoot.querySelector('c-importacao-leads-diagnostico');
    return (diag.diagnostico.bloqueios || []).map((b) => b.mensagem);
}

describe('c-importacao-leads', () => {
    beforeEach(() => {
        mockFormFactor = 'Large';
        getBus.mockResolvedValue([{ value: 'SOL', label: 'Arnone Soluções' }]);
        getPerfis.mockResolvedValue([PERFIL_SOL]);
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('lista no seletor só as BUs devolvidas por getBus (cenário 30)', async () => {
        getBus.mockResolvedValue([
            { value: 'SOL', label: 'Arnone Soluções' },
            { value: 'STE', label: 'Instituto STech' }
        ]);
        const el = await montar();
        const combo = el.shadowRoot.querySelector('lightning-combobox.seletor-bu');
        expect(combo.options).toEqual([
            { label: 'Arnone Soluções', value: 'SOL' },
            { label: 'Instituto STech', value: 'STE' }
        ]);
        expect(getPerfis).not.toHaveBeenCalled();
    });

    it('com uma BU de perfil único, já seleciona os dois e mostra a descrição', async () => {
        const el = await montar();
        expect(getPerfis).toHaveBeenCalledWith({ bu: 'SOL' });
        expect(el.shadowRoot.querySelector('lightning-combobox.seletor-perfil').value).toBe('SOL_Generico');
        expect(el.shadowRoot.querySelector('.perfil-card').textContent).toContain('distribuição automática');
        expect(el.shadowRoot.textContent).toContain('Use o arquivo original do Lemit, sem abrir no Excel');
    });

    it('sem BU permitida, mostra o aviso e nenhum seletor', async () => {
        getBus.mockResolvedValue([]);
        const el = await montar();
        expect(el.shadowRoot.querySelector('lightning-combobox.seletor-bu')).toBeNull();
        expect(el.shadowRoot.textContent).toContain('não tem permissão');
    });

    it('notação científica bloqueia o arquivo antes de qualquer Apex (cenário 27)', async () => {
        const el = await montar();
        await subir(el, 'CNPJ;Razão Social\n4,53413E+13;Empresa A\n11222333000181;Empresa B\n');
        expect(textoBloqueios(el)).toContain(MSG_EXCEL);
        const botao = el.shadowRoot.querySelector('lightning-button.botao-analisar');
        expect(botao.disabled).toBe(true);
        botao.click();
        await flush();
        expect(iniciarLote).not.toHaveBeenCalled();
        expect(adicionarLinhas).not.toHaveBeenCalled();
    });

    it('cabeçalho Lemit no perfil genérico mostra a mensagem de próxima fase (cenário 28)', async () => {
        const el = await montar();
        const linha = ['86066846', '4,53413E+13', 'NELSON', '7488619000136 | 58844234000103 |', '16', '996343819', '1', '', '', '', '', '', '', '', '', ''];
        await subir(el, CABECALHO_LEMIT.join(';') + '\n' + linha.join(';') + '\n');
        const msgs = textoBloqueios(el);
        expect(msgs).toContain(MSG_LEMIT);
        expect(msgs).toContain(MSG_EXCEL);
        expect(el.shadowRoot.querySelector('lightning-button.botao-analisar').disabled).toBe(true);
        expect(iniciarLote).not.toHaveBeenCalled();
    });

    it('arquivo limpo libera Analisar e envia as linhas como JSON string', async () => {
        iniciarLote.mockResolvedValue('a0X000000000001');
        adicionarLinhas.mockResolvedValue();
        classificar.mockResolvedValue({
            loteId: 'a0X000000000001',
            loteNome: 'IMP-000001',
            total: 1,
            matchUnico: 0,
            matchMultiplo: 0,
            semMatch: 1,
            convertido: 0,
            jaContato: 0,
            invalido: 0,
            duplicado: 0,
            criarSemMatch: true,
            modoDono: 'DISTRIBUICAO_SOL',
            chave: 'CNPJ',
            multiplos: [],
            amostra: [{ linhaId: 'l1', numeroLinha: 1, chaveOriginal: '11222333000181', resultadoMatch: 'SEM_MATCH', acao: 'CRIAR', resumo: '' }]
        });
        const el = await montar();
        await subir(el, 'CNPJ;Razão Social;Telefone\n11222333000181;Empresa B;1133334444\n');
        expect(textoBloqueios(el)).toEqual([]);
        const botao = el.shadowRoot.querySelector('lightning-button.botao-analisar');
        expect(botao.disabled).toBe(false);
        botao.click();
        await flush();
        await flush();
        expect(iniciarLote).toHaveBeenCalledWith(
            expect.objectContaining({ perfilDeveloperName: 'SOL_Generico', totalLinhas: 1 })
        );
        const linhas = JSON.parse(adicionarLinhas.mock.calls[0][0].linhasJson);
        expect(linhas[0]).toEqual({
            numeroLinha: 1,
            chave: '11222333000181',
            valores: { Phone: '1133334444', Company: 'Empresa B', LastName: 'Empresa B' }
        });
        expect(el.shadowRoot.querySelector('.confirmacao').textContent).toContain(
            '1 leads serão criados e distribuídos.'
        );
    });
});
