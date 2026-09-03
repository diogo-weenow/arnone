/**
 * CLICKUP-9421 — Entrada da criação automática da tarefa de acompanhamento do
 * cálculo jurídico.
 *
 * Camada fina entre o Record-Triggered Flow SOL_Tarefa_Acompanhamento_Calculo
 * (after-save em Opportunity) e SOLAcompanhamentoCalculoService. NÃO duplica
 * lógica, não faz SOQL nem DML.
 *
 * Tratamento de falha ATÔMICO: se a tarefa não puder ser criada (inclusive
 * calendário ausente), a exceção controlada é RELANÇADA para o Flow. Como o
 * Flow chama esta ação com flowTransactionModel = CurrentTransaction, a exceção
 * aborta a transação inteira — e é isso que desfaz o registro da data da
 * solicitação (CLICKUP-9420). O vendedor recebe a mensagem controlada; o
 * detalhe técnico fica só no log de debug.
 *
 * Mesmo comportamento em teste e em produção.
 */
public with sharing class SOLAcompanhamentoCalculoInvocable {
  public class Entrada {
    @InvocableVariable(
      label='Id da Oportunidade'
      description='Oportunidade que registrou a solicitação do cálculo jurídico.'
      required=true
    )
    public Id opportunityId;
  }

  @InvocableMethod(
    label='Criar tarefa de acompanhamento do cálculo jurídico SOL'
    description='Consolida os Ids recebidos e chama SOLAcompanhamentoCalculoService.criarTarefaAcompanhamento uma única vez por execução bulk.'
    category='Arnone Soluções'
  )
  public static void criar(List<Entrada> entradas) {
    if (entradas == null || entradas.isEmpty()) {
      return;
    }

    Set<Id> ids = new Set<Id>();
    for (Entrada entrada : entradas) {
      if (
        entrada != null &&
        entrada.opportunityId != null &&
        entrada.opportunityId.getSObjectType() == Opportunity.SObjectType
      ) {
        ids.add(entrada.opportunityId);
      }
    }
    if (ids.isEmpty()) {
      return;
    }

    try {
      SOLAcompanhamentoCalculoService.criarTarefaAcompanhamento(new List<Id>(ids));
    } catch (SOLAcompanhamentoCalculoService.AcompanhamentoCalculoException e) {
      System.debug(
        LoggingLevel.ERROR,
        'SOLAcompanhamentoCalculoInvocable: ' + e.getMessage()
      );
      throw e;
    } catch (Exception e) {
      System.debug(
        LoggingLevel.ERROR,
        'SOLAcompanhamentoCalculoInvocable: ' + e.getTypeName() + ': ' + e.getMessage()
      );
      throw new SOLAcompanhamentoCalculoService.AcompanhamentoCalculoException(
        SOLAcompanhamentoCalculoService.MSG_FALHA
      );
    }
  }
}
