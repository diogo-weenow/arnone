/**
 * CLICKUP-9439 / CLICKUP-9429 (absorvido) — porta dos Flows de marco para
 * `SOLDuracaoEtapaService`.
 *
 * Camada fina: consolida os Ids recebidos, separa Lead de Oportunidade pelo
 * prefixo do próprio Id e chama o serviço UMA vez por tipo. Não faz SOQL, não
 * faz DML, não duplica regra nenhuma.
 *
 * ==========================================================
 * DIVERGÊNCIA DELIBERADA EM RELAÇÃO À PORTA ESTRITA DO 9449
 * ==========================================================
 * `SOLContatoEfetivadoInvocable` tem a FORMA que esta classe imita —
 * `@InvocableVariable`, consolidação em `Set<Id>`, descarte do SObject errado
 * — e a SEMÂNTICA OPOSTA quanto a erro: lá, uma referência inválida ou um lead
 * em estado terminal DERRUBAM a transação de propósito, porque deixar passar
 * gravaria um dado falso (a tarefa afirmando que o lead respondeu).
 *
 * Aqui NUNCA se relança. A razão não é conveniência: a duração é medida
 * ANALÍTICA, e a decisão do P.O. (Opção B) é explícita — falha exclusivamente
 * analítica não pode desfazer reunião, contato, procuração, cálculo ou
 * fechamento. Engolir aqui também não persiste nada falso: o marco comercial
 * fica gravado, a duração fica VAZIA e a pendência fica registrada em
 * `SOL_Duracao_Pendente__c` + motivo + detalhe, visível na lista operacional.
 *
 * O serviço já não lança; este `try/catch` é a segunda cerca, para que nem uma
 * falha inesperada de plataforma volte para o Flow e aborte o save do vendedor.
 */
public with sharing class SOLDuracaoEtapaInvocable {
  public class Entrada {
    /**
     * `required=false` de propósito: um Flow que não encontrou o registro do
     * `WhoId`/`WhatId` passa null aqui, e null tem de ser DESCARTADO em
     * silêncio, não virar erro na cara do vendedor. Quem precisa recusar
     * referência inválida é a porta estrita do contato efetivado, não esta.
     */
    @InvocableVariable(
      label='Id do Lead ou da Oportunidade'
      description='Registro cujas durações por etapa devem ser reavaliadas. Nulo ou de outro objeto é ignorado.'
      required=false
    )
    public Id recordId;
  }

  @InvocableMethod(
    label='Recalcular durações por etapa SOL'
    description='Reavalia as durações em dias úteis das etapas do Lead ou da Oportunidade. Nunca falha: sem calendário, a duração fica vazia e a pendência é registrada.'
    category='Arnone Soluções'
  )
  public static void recalcular(List<Entrada> entradas) {
    if (entradas == null || entradas.isEmpty()) {
      return;
    }

    Set<Id> leadIds = new Set<Id>();
    Set<Id> oppIds = new Set<Id>();
    for (Entrada entrada : entradas) {
      if (entrada == null || entrada.recordId == null) {
        continue;
      }
      Schema.SObjectType tipo = entrada.recordId.getSObjectType();
      if (tipo == Lead.SObjectType) {
        leadIds.add(entrada.recordId);
      } else if (tipo == Opportunity.SObjectType) {
        oppIds.add(entrada.recordId);
      }
      // Qualquer outro objeto é descartado: é um Flow apontando para um
      // Contact, uma Account ou um Case, e medir duração ali não faz sentido.
    }

    try {
      if (!leadIds.isEmpty()) {
        System.debug(
          LoggingLevel.INFO,
          'SOLDuracaoEtapaInvocable (Lead): ' +
            SOLDuracaoEtapaService.recalcularLeads(new List<Id>(leadIds))
        );
      }
      if (!oppIds.isEmpty()) {
        System.debug(
          LoggingLevel.INFO,
          'SOLDuracaoEtapaInvocable (Opportunity): ' +
            SOLDuracaoEtapaService.recalcularOportunidades(new List<Id>(oppIds))
        );
      }
    } catch (Exception e) {
      // Segunda cerca. Nenhuma operação comercial cai por causa da medição.
      System.debug(
        LoggingLevel.ERROR,
        'SOLDuracaoEtapaInvocable: ' +
          e.getTypeName() +
          ': ' +
          e.getMessage() +
          ' | ' +
          e.getStackTraceString()
      );
    }
  }
}
