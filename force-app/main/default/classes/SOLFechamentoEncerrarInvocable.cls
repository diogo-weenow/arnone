/**
 * CLICKUP-9423 — Entrada do EVENTO 2: encerramento das tarefas de fechamento.
 *
 * Camada fina entre o Record-Triggered Flow SOL_Encerrar_Fechamento_Ganho_Perdido
 * (after-save em Opportunity) e SOLFechamentoService.encerrarTarefasFechamento.
 * NÃO duplica lógica, não faz SOQL nem DML.
 *
 * Falha ATÔMICA: se a conclusão das Tasks falhar, a exceção controlada é
 * RELANÇADA para o Flow. Como o Flow chama esta ação com flowTransactionModel =
 * CurrentTransaction, a exceção aborta a mudança da Oportunidade para
 * Ganho/Perdido com mensagem controlada.
 */
public with sharing class SOLFechamentoEncerrarInvocable {
  public class Entrada {
    @InvocableVariable(
      label='Id da Oportunidade'
      description='Oportunidade que virou Ganho ou Perdido.'
      required=true
    )
    public Id opportunityId;
  }

  @InvocableMethod(
    label='Concluir tarefas de fechamento ao encerrar a Oportunidade SOL'
    description='Consolida os Ids recebidos e chama SOLFechamentoService.encerrarTarefasFechamento uma única vez por execução bulk.'
    category='Arnone Soluções'
  )
  public static void encerrar(List<Entrada> entradas) {
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
      SOLFechamentoService.encerrarTarefasFechamento(new List<Id>(ids));
    } catch (SOLFechamentoService.FechamentoException e) {
      System.debug(LoggingLevel.ERROR, 'SOLFechamentoEncerrarInvocable: ' + e.getMessage());
      throw e;
    } catch (Exception e) {
      System.debug(
        LoggingLevel.ERROR,
        'SOLFechamentoEncerrarInvocable: ' + e.getTypeName() + ': ' + e.getMessage()
      );
      throw new SOLFechamentoService.FechamentoException(SOLFechamentoService.MSG_FALHA_ENCERRAR);
    }
  }
}
