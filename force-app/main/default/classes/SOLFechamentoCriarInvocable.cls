/**
 * CLICKUP-9423 — Entrada do EVENTO 1: criação da tarefa de fechamento.
 *
 * Camada fina entre o Record-Triggered Flow SOL_Tarefa_Fechamento_Apos_Reuniao
 * (after-save em Task) e SOLFechamentoService.criarTarefaFechamento. NÃO duplica
 * lógica, não faz SOQL nem DML.
 *
 * Falha ATÔMICA: a exceção controlada é RELANÇADA para o Flow. Como o Flow
 * chama esta ação com flowTransactionModel = CurrentTransaction, a exceção
 * aborta a transação inteira — desfazendo também a conclusão da Task de reunião
 * final.
 */
public with sharing class SOLFechamentoCriarInvocable {
  public class Entrada {
    @InvocableVariable(
      label='Id da Task de reunião final'
      description='Task "Reunião final" que foi concluída.'
      required=true
    )
    public Id taskId;
  }

  @InvocableMethod(
    label='Criar tarefa de fechamento após a reunião final SOL'
    description='Consolida os Ids recebidos e chama SOLFechamentoService.criarTarefaFechamento uma única vez por execução bulk.'
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
        entrada.taskId != null &&
        entrada.taskId.getSObjectType() == Task.SObjectType
      ) {
        ids.add(entrada.taskId);
      }
    }
    if (ids.isEmpty()) {
      return;
    }

    try {
      SOLFechamentoService.criarTarefaFechamento(new List<Id>(ids));
    } catch (SOLFechamentoService.FechamentoException e) {
      System.debug(LoggingLevel.ERROR, 'SOLFechamentoCriarInvocable: ' + e.getMessage());
      throw e;
    } catch (Exception e) {
      System.debug(
        LoggingLevel.ERROR,
        'SOLFechamentoCriarInvocable: ' + e.getTypeName() + ': ' + e.getMessage()
      );
      throw new SOLFechamentoService.FechamentoException(SOLFechamentoService.MSG_FALHA_CRIAR);
    }
  }
}
