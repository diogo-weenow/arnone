/**
 * CLICKUP-9420 — Entrada da ação guiada "Solicitar cálculo (jurídico)".
 *
 * Camada fina entre o Screen Flow SOL_Solicitar_Calculo (Quick Action na
 * Opportunity) e SOLSolicitarCalculoService. NÃO duplica lógica; não faz SOQL
 * nem DML.
 *
 * Validações de negócio falham com MENSAGEM CONTROLADA (retorno, sem gravar).
 * Falha técnica na gravação RELANÇA SolicitacaoCalculoException — o Flow mostra
 * a mensagem controlada pelo caminho de falha.
 */
public with sharing class SOLSolicitarCalculoInvocable {
  public class Entrada {
    @InvocableVariable(label='Id da Oportunidade' required=true)
    public Id opportunityId;

    @InvocableVariable(label='Data da solicitação do cálculo' required=true)
    public Date dataSolicitacao;
  }

  public class Saida {
    @InvocableVariable(label='Sucesso')
    public Boolean sucesso;

    @InvocableVariable(label='Já registrado')
    public Boolean jaRegistrado;

    @InvocableVariable(label='Mensagem')
    public String mensagem;
  }

  @InvocableMethod(
    label='Registrar solicitação do cálculo jurídico (SOL)'
    description='Valida os pré-requisitos e grava Opportunity.SOL_Data_Solicitacao_Calculo__c uma única vez.'
    category='Arnone Soluções'
  )
  public static List<Saida> registrar(List<Entrada> entradas) {
    List<Saida> saidas = new List<Saida>();
    if (entradas == null || entradas.isEmpty()) {
      return saidas;
    }

    List<SOLSolicitarCalculoService.Pedido> pedidos = new List<SOLSolicitarCalculoService.Pedido>();
    for (Entrada e : entradas) {
      pedidos.add(
        new SOLSolicitarCalculoService.Pedido(
          e == null ? null : e.opportunityId,
          e == null ? null : e.dataSolicitacao
        )
      );
    }

    List<SOLSolicitarCalculoService.Resultado> resultados;
    try {
      resultados = SOLSolicitarCalculoService.registrar(pedidos);
    } catch (SOLSolicitarCalculoService.SolicitacaoCalculoException ex) {
      System.debug(LoggingLevel.ERROR, 'SOLSolicitarCalculoInvocable: ' + ex.getMessage());
      throw ex;
    } catch (Exception ex) {
      System.debug(
        LoggingLevel.ERROR,
        'SOLSolicitarCalculoInvocable: ' + ex.getTypeName() + ': ' + ex.getMessage()
      );
      throw new SOLSolicitarCalculoService.SolicitacaoCalculoException(
        SOLSolicitarCalculoService.MSG_FALHA
      );
    }

    for (SOLSolicitarCalculoService.Resultado r : resultados) {
      Saida s = new Saida();
      s.sucesso = r.sucesso;
      s.jaRegistrado = r.jaRegistrado;
      s.mensagem = r.mensagem;
      saidas.add(s);
    }
    return saidas;
  }
}
