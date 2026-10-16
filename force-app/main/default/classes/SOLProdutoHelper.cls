/**
 * Revisão trabalhista — produto multi-select (Opção A: UMA Oportunidade carrega
 * VÁRIOS produtos). Fonte ÚNICA de leitura dos dois campos de produto da Arnone
 * Soluções agora multivalorados:
 *
 *   - Lead.SOL_Produto_Interesse__c
 *   - Opportunity.SOL_Produto_Negocio__c
 *
 * Os dois passaram de Picklist para Multi-Select Picklist. O valor é uma string
 * com os produtos separados por ';' (uma seleção única continua sendo a string
 * crua, sem ';'). Toda comparação que antes era `== 'Recuperação Tributária'`
 * passa a chamar {@link #contem} ou {@link #contemAlgum}.
 *
 * POR QUE UM HELPER E NÃO `.split(';')` ESPALHADO: o `split` solto em cada
 * serviço reabriria, um ponto de cada vez, o defeito de voltar a tratar
 * "ART 360;Revisão trabalhista" como UM produto inexistente. A semântica de
 * "contém" vive aqui, uma vez só, coberta por teste.
 *
 * SEMÂNTICA DO CARD — UNIÃO DO MAIS EXIGENTE: se QUALQUER produto selecionado
 * exige um portão, o portão vale. Por isso os serviços perguntam "contém RT?",
 * "contém RT ou ART?" ou "contém qualquer um dos três?", nunca igualdade.
 */
public inherited sharing class SOLProdutoHelper {
  public static final String PRODUTO_RECUPERACAO = 'Recuperação Tributária';
  public static final String PRODUTO_ART = 'ART 360';
  public static final String PRODUTO_REVISAO = 'Revisão trabalhista';

  /** Os três produtos da unidade SOL, para o teste "contém qualquer um". */
  public static final Set<String> PRODUTOS_SOL = new Set<String>{
    PRODUTO_RECUPERACAO,
    PRODUTO_ART,
    PRODUTO_REVISAO
  };

  /**
   * Os produtos selecionados no campo multi-valor, já sem espaços e sem vazios.
   * Null ou string em branco devolve conjunto VAZIO — nunca um conjunto com ''
   * dentro, que furaria o `contains`.
   */
  public static Set<String> valores(String multiValor) {
    Set<String> selecionados = new Set<String>();
    if (String.isBlank(multiValor)) {
      return selecionados;
    }
    for (String parte : multiValor.split(';')) {
      String limpo = parte == null ? null : parte.trim();
      if (String.isNotBlank(limpo)) {
        selecionados.add(limpo);
      }
    }
    return selecionados;
  }

  /** O campo multi-valor inclui ESTE produto. */
  public static Boolean contem(String multiValor, String produto) {
    if (String.isBlank(produto)) {
      return false;
    }
    return valores(multiValor).contains(produto);
  }

  /** O campo multi-valor inclui QUALQUER um dos produtos informados. */
  public static Boolean contemAlgum(String multiValor, Set<String> produtos) {
    if (produtos == null || produtos.isEmpty()) {
      return false;
    }
    Set<String> selecionados = valores(multiValor);
    for (String produto : produtos) {
      if (selecionados.contains(produto)) {
        return true;
      }
    }
    return false;
  }

  /**
   * Lista de produtos para emitir UM evento de jornada por produto. Campo vazio
   * devolve uma lista com um único elemento null, para que a ocorrência NÃO seja
   * descartada: o evento nasce com SOL_Produto__c = null, como o card pede.
   */
  public static List<String> paraEventos(String multiValor) {
    Set<String> selecionados = valores(multiValor);
    if (selecionados.isEmpty()) {
      return new List<String>{ null };
    }
    return new List<String>(selecionados);
  }

  /**
   * Troca o separador ';' por ', ' para exibição legível (nome da Oportunidade).
   * Não altera a semântica — só o rótulo.
   */
  public static String paraRotulo(String multiValor) {
    return String.isBlank(multiValor)
      ? multiValor
      : multiValor.replace(';', ', ');
  }
}
