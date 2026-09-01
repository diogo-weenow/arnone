/** Resolve a classificação do candidato a partir da MessagingSession. */
public without sharing class STE_RoutingResolver {
  public class Entrada {
    @InvocableVariable(label='ID da sessão' required=true)
    public String sessionId;
  }

  public class Resultado {
    @InvocableVariable(label='Classificação')
    public String classificacao;
    @InvocableVariable(label='ID do candidato')
    public String recordId;
    @InvocableVariable(label='Tipo do candidato')
    public String tipoRegistro;
  }

  @InvocableMethod(
    label='Resolver classificação STech pela sessão'
    description='Localiza Lead ou Contato pelo ID da MessagingSession e devolve a classificação de fila.'
    category='Stech Telecom'
  )
  public static List<Resultado> resolver(List<Entrada> entradas) {
    List<Resultado> resultados = new List<Resultado>();
    if (entradas == null || entradas.isEmpty())
      return resultados;

    Set<String> sessoes = new Set<String>();
    for (Entrada entrada : entradas) {
      String sessao = sessaoValida(entrada == null ? null : entrada.sessionId);
      if (sessao != null)
        sessoes.add(sessao);
      resultados.add(new Resultado());
    }

    Map<String, Lead> leadPorSessao = new Map<String, Lead>();
    for (Lead lead : [
      SELECT Id, STE_MessagingSession_Id__c, STE_Classificacao_Fila__c
      FROM Lead
      WHERE STE_MessagingSession_Id__c IN :sessoes AND IsConverted = FALSE
      ORDER BY LastModifiedDate DESC
    ]) {
      if (!leadPorSessao.containsKey(lead.STE_MessagingSession_Id__c)) {
        leadPorSessao.put(lead.STE_MessagingSession_Id__c, lead);
      }
    }

    Map<String, Contact> contatoPorSessao = new Map<String, Contact>();
    for (Contact contato : [
      SELECT Id, STE_MessagingSession_Id__c, STE_Classificacao_Fila__c
      FROM Contact
      WHERE STE_MessagingSession_Id__c IN :sessoes
      ORDER BY LastModifiedDate DESC
    ]) {
      if (!contatoPorSessao.containsKey(contato.STE_MessagingSession_Id__c)) {
        contatoPorSessao.put(contato.STE_MessagingSession_Id__c, contato);
      }
    }

    for (Integer i = 0; i < entradas.size(); i++) {
      String sessao = sessaoValida(
        entradas[i] == null ? null : entradas[i].sessionId
      );
      Resultado resultado = resultados[i];
      if (leadPorSessao.containsKey(sessao)) {
        Lead lead = leadPorSessao.get(sessao);
        resultado.classificacao = lead.STE_Classificacao_Fila__c;
        resultado.recordId = String.valueOf(lead.Id);
        resultado.tipoRegistro = 'Lead';
      } else if (contatoPorSessao.containsKey(sessao)) {
        Contact contato = contatoPorSessao.get(sessao);
        resultado.classificacao = contato.STE_Classificacao_Fila__c;
        resultado.recordId = String.valueOf(contato.Id);
        resultado.tipoRegistro = 'Contact';
      }
    }
    return resultados;
  }

  private static String sessaoValida(String valor) {
    if (String.isBlank(valor))
      return null;
    try {
      Id candidato = (Id) valor.trim();
      return candidato.getSObjectType() == MessagingSession.SObjectType
        ? String.valueOf(candidato)
        : null;
    } catch (Exception e) {
      return null;
    }
  }
}