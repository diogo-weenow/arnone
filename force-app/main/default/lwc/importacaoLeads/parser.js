/**
 * Importação de leads — funções puras de leitura e diagnóstico do arquivo.
 * Sem DOM e sem Apex, para serem testadas isoladamente.
 */

export const MSG_EXCEL =
    'Este arquivo foi aberto e salvo no Excel, que converteu CPF/CNPJ em notação científica (ex.: 4,53413E+13) e apagou dígitos. Não é possível recuperar. Suba o arquivo original exportado do Lemit, sem abrir no Excel.';

export const MSG_LEMIT =
    'Este é um arquivo Lemit de empresas e sócios. O perfil Lemit será liberado na próxima fase.';

/** Cabeçalho exato do arquivo Lemit de empresas e sócios. */
export const CABECALHO_LEMIT = [
    'CPF/CNPJ',
    'CPF/CNPJ_ATRELADO',
    'NOME/RAZAO_SOCIAL',
    'EMPRESAS_ASSOCIADAS',
    'DDD1',
    'CELULAR1',
    'WHATS1',
    'DDD2',
    'CELULAR2',
    'WHATS2',
    'DDD3',
    'CELULAR3',
    'WHATS3',
    'DDD4',
    'CELULAR4',
    'WHATS4'
];

/** Colunas-chave do layout Lemit (onde o Excel costuma gerar notação científica). */
export const CHAVES_LEMIT = ['CPF/CNPJ', 'CPF/CNPJ_ATRELADO'];

const RE_NOTACAO = /^\d+([.,]\d+)?[eE][+-]?\d+$/;

const DELIMITADORES = [
    { valor: ';', rotulo: 'Ponto e vírgula (;)' },
    { valor: ',', rotulo: 'Vírgula (,)' },
    { valor: '\t', rotulo: 'Tabulação' }
];

/**
 * Decodifica os bytes: UTF-8 estrito; se falhar, windows-1252. Remove o BOM.
 * @param {Uint8Array} bytes
 * @returns {{texto: string, encoding: string}}
 */
export function decodificar(bytes) {
    let texto;
    let encoding = 'UTF-8';
    try {
        // ignoreBOM: mantém o BOM no texto para removê-lo (e reportá-lo) abaixo.
        texto = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes);
    } catch {
        texto = new TextDecoder('windows-1252').decode(bytes);
        encoding = 'Windows-1252';
    }
    if (texto.charCodeAt(0) === 0xfeff) {
        texto = texto.slice(1);
        encoding += ' (com BOM)';
    }
    return { texto, encoding };
}

/** Primeira linha não vazia do texto. */
export function linhaCabecalho(texto) {
    const linhas = String(texto || '').split(/\r?\n/);
    return linhas.find((l) => l.trim() !== '') || '';
}

/**
 * Delimitador mais frequente entre ';', ',' e TAB na linha de cabeçalho.
 * Empate fica com a ordem ; , TAB.
 */
export function detectarDelimitador(texto) {
    const cab = linhaCabecalho(texto);
    let melhor = DELIMITADORES[0];
    let max = -1;
    DELIMITADORES.forEach((d) => {
        const n = cab.split(d.valor).length - 1;
        if (n > max) {
            max = n;
            melhor = d;
        }
    });
    return { valor: melhor.valor, rotulo: melhor.rotulo };
}

export function ehNotacaoCientifica(valor) {
    return (
        valor !== undefined &&
        valor !== null &&
        RE_NOTACAO.test(String(valor).trim())
    );
}

/** True quando o cabeçalho é exatamente o do Lemit de empresas e sócios. */
export function ehCabecalhoLemit(campos) {
    const c = (campos || []).map((x) => String(x || '').trim());
    return (
        c.length === CABECALHO_LEMIT.length &&
        c.every((x, i) => x === CABECALHO_LEMIT[i])
    );
}

/** Nome de coluna sem acento, caixa, espaço ou pontuação, para casar sugestões. */
export function normalizarNome(s) {
    return String(s || '')
        .toLowerCase()
        .normalize('NFD')
        .replace(/[̀-ͯ]/g, '')
        .replace(/[^a-z0-9]/g, '');
}

/** Cabeçalho do arquivo que casa com a coluna sugerida, ou ''. */
export function casarColuna(cabecalhos, sugestao) {
    if (!sugestao) {
        return '';
    }
    const alvo = normalizarNome(sugestao);
    return (cabecalhos || []).find((h) => normalizarNome(h) === alvo) || '';
}

/** True quando algum valor da coluna está em notação científica. */
export function colunaTemNotacao(linhas, coluna) {
    if (!coluna) {
        return false;
    }
    return (linhas || []).some((r) => ehNotacaoCientifica(r[coluna]));
}

/** Lê o arquivo como bytes (FileReader funciona no navegador e no app). */
export function lerBytes(arquivo) {
    return new Promise((resolve, reject) => {
        const leitor = new FileReader();
        leitor.onload = () => resolve(new Uint8Array(leitor.result));
        leitor.onerror = () => reject(leitor.error);
        leitor.readAsArrayBuffer(arquivo);
    });
}
