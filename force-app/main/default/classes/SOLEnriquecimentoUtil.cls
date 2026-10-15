/**
 * Upload enriquecimento Lemit — utilitários puros compartilhados pelo
 * controller, pelo batch de processamento e pelo backfill de CNPJ.
 *
 * Sem SOQL, sem DML, sem estado. A normalização aqui é IDÊNTICA à do Flow
 * before-save Lead_BeforeSave_Normalizar_CNPJ (remove ponto, barra, hífen e
 * espaço): as duas precisam casar, senão o Lead gravado pelo Flow e a chave de
 * busca do enriquecimento divergiriam e o match falharia em silêncio.
 */
public with sharing class SOLEnriquecimentoUtil {
  /**
   * CNPJ somente dígitos. Remove exatamente os mesmos quatro caracteres que o
   * Flow before-save remove: '.', '/', '-' e ' '. Qualquer outro caractere
   * permanece — e, como o resultado deixa de ter 14 dígitos, a linha cai no
   * balde INVALIDO, que é o comportamento desejado.
   */
  public static String normalizarCnpj(String bruto) {
    if (String.isBlank(bruto)) {
      return '';
    }
    return bruto.replace('.', '')
      .replace('/', '')
      .replace('-', '')
      .replace(' ', '')
      .trim();
  }

  /** True quando o CNPJ normalizado tem exatamente 14 dígitos numéricos. */
  public static Boolean cnpjValido(String normalizado) {
    return String.isNotBlank(normalizado) &&
      normalizado.length() == 14 &&
      normalizado.isNumeric();
  }

  /**
   * Formata 14 dígitos na máscara 00.000.000/0001-00. Entrada que não tenha
   * 14 dígitos é devolvida como veio — o chamador já tratou a validade.
   */
  public static String formatarCnpj(String normalizado) {
    if (!cnpjValido(normalizado)) {
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
}
