/**
 * CLICKUP-9426 — Entrada da criação automática da tarefa de acompanhamento da
 * procuração.
 *
 * Camada fina entre o Record-Triggered Flow SOL_Tarefa_Acompanhamento_Procuracao
 * (after-save em Lead) e SOLProcuracaoAcompanhamentoService. NÃO duplica lógica,
 * não faz SOQL nem DML.
 *
 * Tratamento de falha ATÔMICO: se a tarefa não puder ser criada (inclusive
 * calendário ausente), a exceção controlada é RELANÇADA para o Flow. Como o
 * Flow chama esta ação com flowTransactionModel = CurrentTransaction, a exceção
 * aborta a transação inteira — e é isso que desfaz o registro da solicitação
 * (Status + campos do Lead). O vendedor recebe a mensagem controlada. Detalhe
 * técnico só no log de debug.
 *
 * Mesmo comportamento em teste e em produção.
 */
public with sharing class SOLProcuracaoAcompanhamentoInvocable {
  public class Entrada {
    @InvocableVariable(
      label='Id do Lead'
      description='Lead que registrou a solicitação da procuração.'
      required=true
    )
    public Id leadId;
  }

  @InvocableMethod(
    label='Criar tarefa de acompanhamento da procuração SOL'
    description='Consolida os Ids recebidos e chama SOLProcuracaoAcompanhamentoService.criarTarefaAcompanhamento uma única vez por execução bulk.'
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
        entrada.leadId != null &&
        entrada.leadId.getSObjectType() == Lead.SObjectType
      ) {
        ids.add(entrada.leadId);
      }
    }
    if (ids.isEmpty()) {
      return;
    }

    try {
      SOLProcuracaoAcompanhamentoService.criarTarefaAcompanhamento(new List<Id>(ids));
    } catch (SOLProcuracaoAcompanhamentoService.AcompanhamentoException e) {
      System.debug(
        LoggingLevel.ERROR,
        'SOLProcuracaoAcompanhamentoInvocable: ' + e.getMessage()
      );
      throw e;
    } catch (Exception e) {
      System.debug(
        LoggingLevel.ERROR,
        'SOLProcuracaoAcompanhamentoInvocable: ' + e.getTypeName() + ': ' + e.getMessage()
      );
      throw new SOLProcuracaoAcompanhamentoService.AcompanhamentoException(
        SOLProcuracaoAcompanhamentoService.MSG_FALHA
      );
    }
  }
}
