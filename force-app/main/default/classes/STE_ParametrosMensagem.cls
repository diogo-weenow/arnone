/**
 * Monta a lista de parâmetros de um componente de mensagem para o Flow.
 *
 * O Flow não consegue construir objetos de tipo Apex-defined, que é o que a ação
 * sendConversationMessages espera em messagingDefinitionInputParameters. Esta classe
 * existe só para preencher essa lacuna: recebe valores simples e devolve a coleção
 * pronta, deixando o envio em si com a ação nativa.
 *
 * Valor em branco não vira parâmetro — o componente que não declara aquela variável
 * recusaria a chamada.
 */
public with sharing class STE_ParametrosMensagem {
  private static final String PARAM_NOME = 'Nome_do_candidato';
  private static final String PARAM_PENDENCIA = 'Pendencia';

  public class Entrada {
    @InvocableVariable(label='Nome do candidato')
    public String nomeCandidato;

    @InvocableVariable(label='Pendência')
    public String pendencia;
  }

  public class Saida {
    @InvocableVariable(label='Parâmetros da mensagem')
    public List<richmessaging.MessageDefinitionInputParameter> parametros;
  }

  @InvocableMethod(
    label='STech — Montar parâmetros da mensagem'
    description='Devolve os parâmetros de um componente de mensagem no formato que a ação de envio espera.'
    category='STech Telecom'
  )
  public static List<Saida> montar(List<Entrada> entradas) {
    List<Saida> saidas = new List<Saida>();
    for (Entrada entrada : entradas) {
      Saida saida = new Saida();
      saida.parametros = new List<richmessaging.MessageDefinitionInputParameter>();
      adicionar(saida.parametros, PARAM_NOME, entrada.nomeCandidato);
      adicionar(saida.parametros, PARAM_PENDENCIA, entrada.pendencia);
      saidas.add(saida);
    }
    return saidas;
  }

  private static void adicionar(
    List<richmessaging.MessageDefinitionInputParameter> destino,
    String nome,
    String valor
  ) {
    if (String.isBlank(valor)) {
      return;
    }
    richmessaging.MessageDefinitionInputParameter parametro = new richmessaging.MessageDefinitionInputParameter();
    parametro.parameterName = nome;
    parametro.textValue = valor;
    destino.add(parametro);
  }
}