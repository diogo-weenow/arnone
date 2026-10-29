import { createElement } from 'lwc';
import ImportacaoLeadsRevisao from 'c/importacaoLeadsRevisao';

const PREVIEW = {
    total: 3,
    matchUnico: 1,
    matchMultiplo: 1,
    semMatch: 0,
    convertido: 0,
    jaContato: 1,
    invalido: 0,
    duplicado: 0,
    criarSemMatch: false,
    chave: 'CPF',
    amostra: [
        { linhaId: 'l1', numeroLinha: 1, chaveOriginal: '12345678909', resultadoMatch: 'MATCH_UNICO', acao: 'ATUALIZAR', resumo: '' },
        { linhaId: 'l3', numeroLinha: 3, chaveOriginal: '11144477735', resultadoMatch: 'JA_CONTATO', acao: 'IGNORAR', resumo: 'Já é contato (aluno ou candidato convertido).' }
    ]
};

const MULTIPLOS = [
    {
        linhaId: 'l2',
        numeroLinha: 2,
        chaveOriginal: '98765432100',
        leadsAlvo: [
            { id: '00Q1', nome: 'Ana', empresa: 'A', owner: 'Fila', selecionado: true },
            { id: '00Q2', nome: 'Bia', empresa: 'B', owner: 'Fila', selecionado: true }
        ]
    }
];

const flush = () => Promise.resolve();

function montar(pequeno) {
    const el = createElement('c-importacao-leads-revisao', { is: ImportacaoLeadsRevisao });
    el.preview = PREVIEW;
    el.multiplos = MULTIPLOS;
    el.pequeno = pequeno;
    document.body.appendChild(el);
    return el;
}

describe('c-importacao-leads-revisao (cenário 29)', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    it('Large: usa lightning-datatable com seleção no múltiplo', async () => {
        const el = montar(false);
        await flush();
        const tabela = el.shadowRoot.querySelector('lightning-datatable.tabela-multiplo');
        expect(tabela).not.toBeNull();
        expect(el.shadowRoot.querySelector('lightning-accordion')).toBeNull();
        expect(tabela.selectedRows).toEqual(['l2|00Q1', 'l2|00Q2']);

        const handler = jest.fn();
        el.addEventListener('selecaochange', handler);
        tabela.dispatchEvent(
            new CustomEvent('rowselection', {
                detail: { selectedRows: [{ linhaId: 'l2', leadId: '00Q1' }] }
            })
        );
        expect(handler.mock.calls[0][0].detail.selecoes).toEqual({ l2: ['00Q1'] });
    });

    it('Small: usa lightning-accordion no lugar da tabela', async () => {
        const el = montar(true);
        await flush();
        expect(el.shadowRoot.querySelector('lightning-accordion.acordeao-multiplo')).not.toBeNull();
        expect(el.shadowRoot.querySelector('lightning-datatable')).toBeNull();
        const tiles = el.shadowRoot.querySelectorAll('button.tile');
        expect(tiles[0].parentElement.className).toContain('slds-size_1-of-2');
    });

    it('mostra o tile "Já é contato" e abre o balde ao clicar', async () => {
        const el = montar(false);
        await flush();
        const tile = Array.from(el.shadowRoot.querySelectorAll('button.tile')).find((b) =>
            b.textContent.includes('Já é contato')
        );
        expect(tile).toBeDefined();
        tile.click();
        await flush();
        const tabela = el.shadowRoot.querySelector('lightning-datatable.tabela-linhas');
        expect(tabela.data.map((r) => r.linhaId)).toEqual(['l3']);
        expect(tile.getAttribute('aria-pressed')).toBe('true');
    });
});
