/**
 * Importação de leads — funções puras de documento (CNPJ e CPF) usadas pelo
 * controller, pelo batch e pelo backfill. Substitui o SOLEnriquecimentoUtil.
 *
 * Sem SOQL, sem DML, sem estado.
 *
 * CNPJ (numérico e alfanumérico): remove '.', '/', '-' e espaço e converte para
 * maiúsculas — a mesma remoção do Flow before-save Lead_BeforeSave_Normalizar_CNPJ,
 * para que a chave gravada no Lead e a chave de busca casem. Só aqui, quando o
 * resultado é todo numérico com 12 ou 13 caracteres, completa com zeros à
 * esquerda (o Excel e algumas exportações cortam o zero inicial).
 *
 * DV do CNPJ pelo módulo 11 com o valor de cada caractere = código ASCII − 48
 * (0..9 continuam 0..9; A=17 ... Z=42), pesos 2 a 9 da direita para a esquerda,
 * resto < 2 vira 0. Fonte: Receita Federal, "Perguntas e respostas — CNPJ
 * alfanumérico", pergunta 14 (exemplo 12.ABC.345/01DE-35).
 */
public with sharing class ImportacaoLeadsDocumento {
  public static final String CHAVE_CNPJ = 'CNPJ';
  public static final String CHAVE_CPF = 'CPF';

  public static final String MOTIVO_NOTACAO = 'NOTACAO_CIENTIFICA';
  public static final String MOTIVO_DV = 'DV_INVALIDO';
  public static final String MOTIVO_TAMANHO = 'TAMANHO_INVALIDO';
  public static final String MOTIVO_AUSENTE = 'CHAVE_AUSENTE';

  private static final Pattern NOTACAO_CIENTIFICA = Pattern.compile(
    '^\\d+([.,]\\d+)?[eE][+-]?\\d+$'
  );
  private static final Pattern CNPJ_FORMATO = Pattern.compile(
    '^[0-9A-Z]{12}[0-9]{2}$'
  );

  // ================================================================== CNPJ

  /** CNPJ sem pontuação, em maiúsculas, com zeros à esquerda se 12/13 dígitos. */
  public static String normalizarCnpj(String bruto) {
    if (String.isBlank(bruto)) {
      return '';
    }
    String s = bruto.replace('.', '')
      .replace('/', '')
      .replace('-', '')
      .replace(' ', '')
      .trim()
      .toUpperCase();
    if (s.isNumeric() && (s.length() == 12 || s.length() == 13)) {
      s = s.leftPad(14, '0');
    }
    return s;
  }

  /** True quando tem 14 caracteres [0-9A-Z], os 2 últimos numéricos e DV correto. */
  public static Boolean cnpjValido(String normalizado) {
    if (
      String.isBlank(normalizado) ||
      !CNPJ_FORMATO.matcher(normalizado).matches()
    ) {
      return false;
    }
    return dvCnpj(normalizado.substring(0, 12)) == normalizado.substring(12);
  }

  /** Os 2 dígitos verificadores de uma base de 12 caracteres [0-9A-Z]. */
  public static String dvCnpj(String base12) {
    String parcial = base12;
    for (Integer passo = 0; passo < 2; passo++) {
      Integer soma = 0;
      Integer peso = 2;
      for (Integer i = parcial.length() - 1; i >= 0; i--) {
        soma += (parcial.charAt(i) - 48) * peso;
        peso = peso == 9 ? 2 : peso + 1;
      }
      Integer resto = Math.mod(soma, 11);
      parcial += String.valueOf(resto < 2 ? 0 : 11 - resto);
    }
    return parcial.substring(12);
  }

  /** Máscara 00.000.000/0000-00. Entrada inválida volta como veio. */
  public static String formatarCnpj(String normalizado) {
    if (
      String.isBlank(normalizado) ||
      !CNPJ_FORMATO.matcher(normalizado).matches()
    ) {
      return normalizado;
    }
    return normalizado.substring(0, 2) +
      '.' +
      normalizado.substring(2, 5) +
      '.' +
      normalizado.substring(5, 8) +
      '/' +
      normalizado.substring(8, 12) +
      '-' +
      normalizado.substring(12, 14);
  }

  // ================================================================== CPF

  /** CPF só com dígitos, completado com zeros até 11. Mais de 11 volta como está. */
  public static String normalizarCpf(String bruto) {
    if (String.isBlank(bruto)) {
      return '';
    }
    String s = bruto.replaceAll('[^0-9]', '');
    if (s.length() > 0 && s.length() < 11) {
      s = s.leftPad(11, '0');
    }
    return s;
  }

  /** True quando tem 11 dígitos e os 2 DV conferem. */
  public static Boolean cpfValido(String normalizado) {
    if (
      String.isBlank(normalizado) ||
      normalizado.length() != 11 ||
      !normalizado.isNumeric()
    ) {
      return false;
    }
    return dvCpf(normalizado.substring(0, 9)) == normalizado.substring(9);
  }

  /** Os 2 dígitos verificadores de uma base de 9 dígitos. */
  public static String dvCpf(String base9) {
    String parcial = base9;
    for (Integer passo = 0; passo < 2; passo++) {
      Integer soma = 0;
      Integer peso = parcial.length() + 1;
      for (Integer i = 0; i < parcial.length(); i++) {
        soma += (parcial.charAt(i) - 48) * peso;
        peso--;
      }
      Integer resto = Math.mod(soma, 11);
      parcial += String.valueOf(resto < 2 ? 0 : 11 - resto);
    }
    return parcial.substring(9);
  }

  /** Máscara 000.000.000-00. */
  public static String formatarCpf(String normalizado) {
    if (
      String.isBlank(normalizado) ||
      normalizado.length() != 11 ||
      !normalizado.isNumeric()
    ) {
      return normalizado;
    }
    return normalizado.substring(0, 3) +
      '.' +
      normalizado.substring(3, 6) +
      '.' +
      normalizado.substring(6, 9) +
      '-' +
      normalizado.substring(9, 11);
  }

  /**
   * Os dois formatos em que o CPF pode estar gravado em Lead.CPF__c e
   * Contact.CPF__c: 11 dígitos e 000.000.000-00.
   */
  public static List<String> formatosCpf(String normalizado) {
    return new List<String>{ normalizado, formatarCpf(normalizado) };
  }

  // ================================================================== comum

  /** True quando o valor parece um número em notação científica (ex.: 4,53413E+13). */
  public static Boolean ehNotacaoCientifica(String valor) {
    return String.isNotBlank(valor) &&
      NOTACAO_CIENTIFICA.matcher(valor.trim()).matches();
  }

  /** Normaliza conforme o tipo de chave do perfil (CNPJ ou CPF). */
  public static String normalizar(String bruto, String tipoChave) {
    return tipoChave == CHAVE_CPF ? normalizarCpf(bruto) : normalizarCnpj(bruto);
  }

  /**
   * Motivo de invalidade da chave como veio no arquivo, ou null se válida.
   * A notação científica é testada no valor ORIGINAL, antes de qualquer limpeza.
   */
  public static String motivoInvalido(String original, String tipoChave) {
    if (String.isBlank(original)) {
      return MOTIVO_AUSENTE;
    }
    if (ehNotacaoCientifica(original)) {
      return MOTIVO_NOTACAO;
    }
    String norm = normalizar(original, tipoChave);
    if (tipoChave == CHAVE_CPF) {
      if (norm.length() != 11) {
        return MOTIVO_TAMANHO;
      }
      return cpfValido(norm) ? null : MOTIVO_DV;
    }
    if (!CNPJ_FORMATO.matcher(norm).matches()) {
      return MOTIVO_TAMANHO;
    }
    return cnpjValido(norm) ? null : MOTIVO_DV;
  }
}
