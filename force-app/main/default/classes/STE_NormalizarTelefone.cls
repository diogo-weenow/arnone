/**
 * Preenche o telefone técnico de identificação em Lead e Contato.
 *
 * O bot grava esse campo direto, a partir do telefone do WhatsApp. Este
 * normalizador cobre as demais origens — web-to-lead, importação, digitação
 * manual — para que o candidato seja reconhecido em qualquer uma delas.
 *
 * Só preenche quando o campo está vazio, de propósito: quando o bot já gravou
 * a identidade do WhatsApp, ela não pode ser trocada por um telefone diferente
 * que esteja no MobilePhone.
 */
public class STE_NormalizarTelefone {
  private static final String CAMPO = 'STE_Telefone_E164__c';

  public static void aplicar(List<SObject> registros) {
    if (registros == null)
      return;
    for (SObject registro : registros) {
      if (String.isNotBlank((String) registro.get(CAMPO)))
        continue;
      String chave = STE_Telefone.chave((String) registro.get('MobilePhone'));
      if (chave == null)
        chave = STE_Telefone.chave((String) registro.get('Phone'));
      if (chave != null)
        registro.put(CAMPO, chave);
    }
  }
}