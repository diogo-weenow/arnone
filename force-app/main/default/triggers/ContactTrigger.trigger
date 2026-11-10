trigger ContactTrigger on Contact(before insert, before update) {
  STE_NormalizarTelefone.aplicar(Trigger.new);
}