import { createElement } from 'lwc';
import SolEnriquecimentoLemit from 'c/solEnriquecimentoLemit';
import getConfiguracao from '@salesforce/apex/SOLEnriquecimentoController.getConfiguracao';

jest.mock(
    '@salesforce/apex/SOLEnriquecimentoController.getConfiguracao',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/SOLEnriquecimentoController.iniciarLote',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/SOLEnriquecimentoController.adicionarLinhas',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/SOLEnriquecimentoController.classificar',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/SOLEnriquecimentoController.confirmar',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/SOLEnriquecimentoController.consultarStatus',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const MAPEAMENTOS = [
    {
        coluna: 'Faturamento Anual',
        campoLead: 'AnnualRevenue',
        label: 'Faturamento anual',
        politica: 'OVERWRITE',
        usarNaCriacao: true,
        tipoConversao: 'CURRENCY',
        ordem: 10
    }
];

function flush() {
    return Promise.resolve();
}

describe('c-sol-enriquecimento-lemit', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('carrega a configuração e mostra o passo de upload', async () => {
        getConfiguracao.mockResolvedValue({
            maxLinhas: 5000,
            mapeamentos: MAPEAMENTOS
        });

        const el = createElement('c-sol-enriquecimento-lemit', {
            is: SolEnriquecimentoLemit
        });
        document.body.appendChild(el);

        // renderedCallback -> loadScript (auto-mock resolve) -> getConfiguracao
        await flush();
        await flush();
        await flush();

        expect(getConfiguracao).toHaveBeenCalled();
        const inputs = el.shadowRoot.querySelectorAll('lightning-input');
        expect(inputs.length).toBeGreaterThan(0);
        expect(inputs[0].type).toBe('file');
    });

    it('renderiza o card de enriquecimento', async () => {
        getConfiguracao.mockResolvedValue({
            maxLinhas: 5000,
            mapeamentos: MAPEAMENTOS
        });
        const el = createElement('c-sol-enriquecimento-lemit', {
            is: SolEnriquecimentoLemit
        });
        document.body.appendChild(el);
        await flush();
        const card = el.shadowRoot.querySelector('lightning-card');
        expect(card).not.toBeNull();
    });
});
