/**
 * Normalização de telefone para identificar o candidato entre conversas.
 *
 * A chave de identificação é o telefone só com dígitos, no formato E.164 sem o
 * sinal de mais (código do país + DDD + número), que é como o WhatsApp entrega
 * o MessagingPlatformKey do MessagingEndUser.
 */
public class STE_Telefone {
  private static final Integer MINIMO_DIGITOS = 10;
  private static final String BRASIL = '55';

  /** Devolve apenas os dígitos do valor, ou null quando não sobrar nada. */
  public static String digitos(String valor) {
    if (String.isBlank(valor))
      return null;
    String limpo = valor.replaceAll('[^0-9]', '');
    return limpo == '' ? null : limpo;
  }

  /**
   * Chave de identificação, ou null quando o número é curto demais.
   *
   * Número local de 10 ou 11 dígitos (DDD + número) recebe o código do país,
   * porque é assim que telefone digitado em formulário costuma chegar — e sem
   * isso ele nunca casaria com o que o WhatsApp entrega, que já vem com o 55.
   */
  public static String chave(String valor) {
    String limpo = digitos(valor);
    if (limpo == null || limpo.length() < MINIMO_DIGITOS)
      return null;
    return limpo.length() <= 11 ? BRASIL + limpo : limpo;
  }

  /**
   * Variantes do mesmo telefone com e sem o nono dígito, para casar registro
   * antigo gravado com 8 dígitos e registro novo com 9. Devolve conjunto vazio
   * quando o valor não serve como chave.
   */
  public static Set<String> variantes(String valor) {
    Set<String> variantes = new Set<String>();
    String limpo = chave(valor);
    if (limpo == null)
      return variantes;
    variantes.add(limpo);
    if (!limpo.startsWith(BRASIL))
      return variantes;
    if (limpo.length() == 13 && limpo.substring(4, 5) == '9') {
      variantes.add(limpo.substring(0, 4) + limpo.substring(5));
    } else if (limpo.length() == 12) {
      variantes.add(limpo.substring(0, 4) + '9' + limpo.substring(4));
    }
    return variantes;
  }
}