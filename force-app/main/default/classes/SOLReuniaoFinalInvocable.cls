/**
 * CLICKUP-9422 — Entrada da preparação da reunião final.
 *
 * Camada fina entre o Record-Triggered Flow SOL_Reuniao_Final_Apos_Calculo
 * (after-save em Task) e SOLReuniaoFinalService. NÃO duplica lógica, não faz
 * SOQL nem DML.
 *
 * Tratamento de falha ATÔMICO: se a etapa não puder avançar (requisitos de
 * e-CAC) ou a Task não puder ser criada (inclusive calendário ausente), a
 * exceção controlada é RELANÇADA para o Flow. Como o Flow chama esta ação com
 * flowTransactionModel = CurrentTransaction, a exceção aborta a transação
 * inteira — e é isso que desfaz a conclusão da Task de acompanhamento. O
 * vendedor recebe a mensagem controlada; o detalhe técnico fica só no log.
 *
 * Mesmo comportamento em teste e em produção.
 */
public with sharing class SOLReuniaoFinalInvocable {
  public class Entrada {
    @InvocableVariable(
      label='Id da Task de acompanhamento'
      description='Task de acompanhamento do cálculo jurídico que foi concluída.'
      required=true
    )
    public Id taskId;
  }

  @InvocableMethod(
    label='Preparar reunião final após o cálculo jurídico SOL'
    description='Consolida os Ids recebidos e chama SOLReuniaoFinalService.prepararReuniaoFinal uma única vez por execução bulk.'
    category='Arnone Soluções'
  )
  public static void preparar(List<Entrada> entradas) {
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
      SOLReuniaoFinalService.prepararReuniaoFinal(new List<Id>(ids));
    } catch (SOLReuniaoFinalService.ReuniaoFinalException e) {
      System.debug(LoggingLevel.ERROR, 'SOLReuniaoFinalInvocable: ' + e.getMessage());
      throw e;
    } catch (Exception e) {
      System.debug(
        LoggingLevel.ERROR,
        'SOLReuniaoFinalInvocable: ' + e.getTypeName() + ': ' + e.getMessage()
      );
      throw new SOLReuniaoFinalService.ReuniaoFinalException(SOLReuniaoFinalService.MSG_FALHA);
    }
  }
}
