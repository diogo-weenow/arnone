/**
 * CLICKUP-9418 — Entrada do opt-out: o Lead pediu para não ser mais contatado.
 *
 * Camada fina entre o Record-Triggered Flow SOL_Opt_Out (after-save em Task) e
 * SOLDistribuicaoService.registrarOptOut. NÃO duplica lógica, não faz SOQL nem
 * DML.
 *
 * Tratamento de falha ATÔMICO: se a desqualificação / cancelamento não puder
 * ser concluída, a exceção controlada é RELANÇADA para o Flow, abortando a
 * transação inteira — a própria conclusão da Task é desfeita — em vez de deixar
 * a Task concluída e o Lead sem desqualificar. O vendedor recebe a mensagem
 * controlada e conclui a tarefa de novo. Detalhe técnico só no log de debug.
 *
 * Mesmo comportamento em teste e em produção.
 */
public with sharing class SOLOptOutInvocable {
  public class Entrada {
    @InvocableVariable(
      label='Id do Lead (WhoId da Task)'
      description='Lead que pediu para não ser mais contatado.'
      required=true
    )
    public Id leadId;
  }

  @InvocableMethod(
    label='Registrar opt-out SOL (desqualifica o Lead e cancela tarefas pendentes)'
    description='Consolida os Ids recebidos e chama SOLDistribuicaoService.registrarOptOut uma única vez por execução bulk.'
    category='Arnone Soluções'
  )
  public static void registrar(List<Entrada> entradas) {
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
      SOLDistribuicaoService.registrarOptOut(new List<Id>(ids));
    } catch (SOLDistribuicaoService.OptOutException e) {
      System.debug(LoggingLevel.ERROR, 'SOLOptOutInvocable: ' + e.getMessage());
      throw e;
    } catch (Exception e) {
      System.debug(
        LoggingLevel.ERROR,
        'SOLOptOutInvocable: ' + e.getTypeName() + ': ' + e.getMessage()
      );
      throw new SOLDistribuicaoService.OptOutException(
        SOLDistribuicaoService.MSG_OPT_OUT_FALHA
      );
    }
  }
}
