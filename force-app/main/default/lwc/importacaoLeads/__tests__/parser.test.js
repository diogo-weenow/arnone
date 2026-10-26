import { TextDecoder as NodeTextDecoder } from 'util';
import {
    decodificar,
    detectarDelimitador,
    ehNotacaoCientifica,
    ehCabecalhoLemit,
    casarColuna,
    colunaTemNotacao,
    CABECALHO_LEMIT
} from '../parser';

const Papa = require('../../../staticresources/papaparse.js');

// jsdom não expõe TextDecoder; o Node expõe, com windows-1252 (full ICU).
global.TextDecoder = NodeTextDecoder;

function bytesWindows1252(texto) {
    // Latin-1 cobre os caracteres usados (ç, ã, é): 1 byte por caractere.
    return Uint8Array.from(Buffer.from(texto, 'latin1'));
}

function ler(bytes) {
    const { texto, encoding } = decodificar(bytes);
    const d = detectarDelimitador(texto);
    const res = Papa.parse(texto, { header: true, delimiter: d.valor, skipEmptyLines: 'greedy' });
    return { encoding, delimitador: d.valor, campos: res.meta.fields, dados: res.data };
}

describe('parser da importação de leads (cenário 26)', () => {
    it('lê UTF-8 com BOM e remove o BOM do primeiro cabeçalho', () => {
        const bytes = Uint8Array.from(
            Buffer.concat([
                Buffer.from([0xef, 0xbb, 0xbf]),
                Buffer.from('CNPJ;Razão Social\n11222333000181;Ação Ltda\n', 'utf8')
            ])
        );
        const r = ler(bytes);
        expect(r.encoding).toBe('UTF-8 (com BOM)');
        expect(r.campos).toEqual(['CNPJ', 'Razão Social']);
        expect(r.dados[0]['Razão Social']).toBe('Ação Ltda');
    });

    it('cai para windows-1252 e lê "ç/ã" corretamente', () => {
        const r = ler(bytesWindows1252('CNPJ;Razão Social\n11222333000181;Construção São João\n'));
        expect(r.encoding).toBe('Windows-1252');
        expect(r.campos).toEqual(['CNPJ', 'Razão Social']);
        expect(r.dados[0]['Razão Social']).toBe('Construção São João');
    });

    it('usa ; como delimitador e mantém " | " dentro das células', () => {
        const texto = 'CNPJ;EMPRESAS_ASSOCIADAS;Cidade, UF\n11222333000181;7488619000136 | 58844234000103 |;Campinas, SP\n';
        const r = ler(Uint8Array.from(Buffer.from(texto, 'utf8')));
        expect(r.delimitador).toBe(';');
        expect(r.dados[0].EMPRESAS_ASSOCIADAS).toBe('7488619000136 | 58844234000103 |');
        expect(r.dados[0]['Cidade, UF']).toBe('Campinas, SP');
    });

    it('detecta vírgula e tabulação pela linha de cabeçalho', () => {
        expect(detectarDelimitador('a,b,c\n1;2;3').valor).toBe(',');
        expect(detectarDelimitador('a\tb\tc\n1,2,3').valor).toBe('\t');
    });

    it('reconhece notação científica', () => {
        expect(ehNotacaoCientifica('4,53413E+13')).toBe(true);
        expect(ehNotacaoCientifica('1.5e10')).toBe(true);
        expect(ehNotacaoCientifica('11222333000181')).toBe(false);
        expect(ehNotacaoCientifica('11.222.333/0001-81')).toBe(false);
        expect(colunaTemNotacao([{ CNPJ: '1' }, { CNPJ: '4,53413E+13' }], 'CNPJ')).toBe(true);
    });

    it('reconhece o cabeçalho exato do Lemit', () => {
        expect(ehCabecalhoLemit(CABECALHO_LEMIT)).toBe(true);
        expect(ehCabecalhoLemit(['CNPJ', 'Razão Social'])).toBe(false);
        expect(ehCabecalhoLemit(CABECALHO_LEMIT.slice(0, 15))).toBe(false);
    });

    it('casa coluna sugerida sem acento e caixa', () => {
        expect(casarColuna(['cnpj', 'RAZAO SOCIAL'], 'Razão Social')).toBe('RAZAO SOCIAL');
        expect(casarColuna(['x'], 'CNPJ')).toBe('');
    });
});
